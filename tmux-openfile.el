;;; tmux-openfile.el --- Emacs <-> tmux open-file bridge -*- lexical-binding: t; -*-

;; Overview
;; --------
;; Lets shell tools ask a running Emacs to open a file by writing a file-spec
;; into a small per-window IPC file that Emacs watches with filenotify.
;; Requires Emacs 29+ (server-after-make-frame-hook).
;;
;; Works with both session types:
;;   - Regular Emacs (emacs -nw): the initial TTY frame is registered immediately
;;     when `tmux-openfile-enable' is called from init.el.
;;   - Daemon + emacsclient (emacs --daemon / emacsclient -t): each new TTY frame
;;     is registered automatically via server-after-make-frame-hook.
;; GUI frames are silently ignored in both cases.
;;
;; Multiple Emacs sessions in the same tmux window are supported via a session
;; list stored in @emacs_openfile_stack.  Each session owns its own IPC file.
;; The first-registered session (leftmost entry) is always the active one;
;; later sessions are standby and take over only when the active session closes.
;; et.zsh reads @emacs_openfile_stack directly and parses the leftmost entry
;; to find the active cmdfile and pane ID.
;;
;; Internal state is keyed by pane-id, which is unique per session even when
;; multiple sessions share the same tmux window.
;;
;; Frame registration flow
;; -----------------------
;;
;;   Emacs TTY frame  →  tmux-openfile--register-frame runs (either immediately
;;     appears            on enable, or via server-after-make-frame-hook)
;;                    →  tmux-openfile--frame-tty: is it a TTY? (display-graphic-p check)
;;                           GUI → returns nil → stops here, nothing happens
;;                           TTY → returns the /dev/pts/N path
;;                    →  tmux-openfile--lookup-tty: runs `tmux list-panes -a'
;;                           to find which window/pane owns that /dev/pts/N
;;                           not in tmux → returns nil → stops here
;;                           in tmux → returns (window_id . pane_id) e.g. (@3 . %5)
;;                    →  guard: pane already registered? → stop (idempotent)
;;                    →  tmux-openfile--make-cmdfile: creates the IPC file
;;                           at $XDG_CACHE_HOME/emacs/tmux-openfile/openfile-<win>-<pane>.cmd
;;                    →  append cmdfile path to @emacs_openfile_stack
;;                    →  tmux-openfile--install-watch: installs filenotify watch on that file
;;
;; Frame deregistration flow
;; -------------------------
;;
;;   Emacs frame      →  delete-frame-functions fires with that frame
;;     closed         →  tmux-openfile--deregister-frame runs
;;                    →  reverse-lookup finds the pane-id for the frame
;;                    →  removes own cmdfile path from @emacs_openfile_stack
;;                           (stack-write unsets the option if the list becomes empty)
;;                    →  file-notify-rm-watch removes the IPC file watch
;;                    →  cmdfile deleted from disk
;;                    →  frame, session, and watch entries removed from internal tables
;;                    →  et.zsh will now use the previous session, or report none
;;
;; Open-file flow (et.zsh → Emacs)
;; --------------------------------
;;
;;   et.zsh FILE      →  reads @emacs_openfile_stack and parses the leftmost entry
;;                    →  writes FILE into the IPC file in-place (no atomic rename,
;;                           so the inode stays stable and the watch keeps working)
;;                    →  filenotify callback fires in Emacs
;;                    →  reads the IPC file and calls tmux-openfile--open-spec
;;                    →  find-file opens the file in the registered frame
;;
;; File-spec format
;; ----------------
;;   /path/to/file
;;   +LINE[:COLUMN] /path/to/file
;;
;; Usage
;; -----
;; Call `tmux-openfile-enable' once (e.g. from init.el).  Registration is then
;; automatic for every subsequent tty frame.
;; Call `tmux-openfile-disable' to stop registering new frames.

(require 'cl-lib)

(defgroup tmux-openfile nil
  "Open files in Emacs via tmux window metadata."
  :group 'external)

(defcustom tmux-openfile-cache-subdir "tmux-openfile"
  "Subdirectory under $XDG_CACHE_HOME/emacs/ for IPC command files."
  :type 'string)

(defcustom tmux-openfile-watch-events '(change)
  "Events passed to `file-notify-add-watch'."
  :type '(repeat symbol))

(defcustom tmux-openfile-stack-option "@emacs_openfile_stack"
  "tmux window user option that stores the ordered session list (leftmost = active)."
  :type 'string)

;; All three tables are keyed by pane-id (e.g. "%5"), which is unique per
;; session even when multiple sessions share the same tmux window.
(defvar tmux-openfile--pane->frame (make-hash-table :test 'equal)
  "Hash table: pane-id → frame for this Emacs process.")

(defvar tmux-openfile--pane->session (make-hash-table :test 'equal)
  "Hash table: pane-id → (win . cmdfile) for this Emacs process's session.")

(defvar tmux-openfile--pane->watch (make-hash-table :test 'equal)
  "Hash table: pane-id → filenotify watch descriptor for this process's cmdfile.")

(defun tmux-openfile--string-empty-p (s)
  "Return t if S is nil or the empty string."
  (or (null s) (= (length s) 0)))

(defun tmux-openfile--xdg-cache-home ()
  "Return the XDG cache home directory with a trailing slash.
Uses $XDG_CACHE_HOME if set, otherwise falls back to ~/.cache."
  (let ((d (or (getenv "XDG_CACHE_HOME")
               (expand-file-name "~/.cache"))))
    (file-name-as-directory (expand-file-name d))))

(defun tmux-openfile--cache-dir ()
  "Return the absolute path to the IPC file cache directory.
Resolves to $XDG_CACHE_HOME/emacs/`tmux-openfile-cache-subdir'."
  (expand-file-name tmux-openfile-cache-subdir
                    (expand-file-name "emacs" (tmux-openfile--xdg-cache-home))))

(defun tmux-openfile--make-cmdfile (window-id pane-id)
  "Return the IPC file path for WINDOW-ID and PANE-ID, creating it if necessary.
Named openfile-<window_id>-<pane_id>.cmd (e.g. openfile-@3-%5.cmd).
The file and its parent directory are created with 0700/0600 permissions."
  (let* ((dir (tmux-openfile--cache-dir))
         (leaf (format "openfile-%s-%s.cmd" window-id pane-id))
         (path (expand-file-name leaf dir)))
    (unless (file-directory-p dir)
      (make-directory dir t)
      (ignore-errors (set-file-modes dir #o700)))
    (unless (file-exists-p path)
      (with-temp-buffer (write-region "" nil path nil 'silent))
      (ignore-errors (set-file-modes path #o600)))
    path))

(defvar tmux-openfile--executable (executable-find "tmux")
  "Cached path to the tmux executable, or nil if not found.")

(defun tmux-openfile--tmux (&rest args)
  "Run tmux ARGS. Return stdout string on success, nil otherwise."
  (when tmux-openfile--executable
    (with-temp-buffer
      (let ((rc (apply #'call-process tmux-openfile--executable nil t nil args)))
        (when (and (numberp rc) (zerop rc))
          (buffer-string))))))

(defun tmux-openfile--stack-read (win)
  "Return the session stack for tmux window WIN as a list of strings.
Each entry is a cmdfile path; leftmost is the active session.  Returns nil if unset."
  (let ((raw (tmux-openfile--tmux "show-options" "-w" "-qv" "-t" win
                                  tmux-openfile-stack-option)))
    (if (or (null raw) (string-empty-p (string-trim raw)))
        nil
      (split-string (string-trim raw) "\x1f" t))))

(defun tmux-openfile--stack-write (win entries)
  "Write ENTRIES (list of strings) back to the stack tmux option for WIN.
Unsets the option if ENTRIES is empty."
  (if entries
      (tmux-openfile--tmux "set-option" "-w" "-t" win
                           tmux-openfile-stack-option
                           (mapconcat #'identity entries "\x1f"))
    (tmux-openfile--tmux "set-option" "-w" "-t" win "-u"
                         tmux-openfile-stack-option)))

(defun tmux-openfile--lookup-tty (tty)
  "Return a cons (WINDOW-ID . PANE-ID) for the tmux pane whose tty equals TTY, or nil."
  (let* ((out (tmux-openfile--tmux "list-panes" "-a" "-F" "#{pane_tty}\t#{window_id}\t#{pane_id}"))
         (lines (and out (split-string out "\n" t))))
    (cl-loop for line in lines
             for parts = (split-string line "\t")
             for ptty = (nth 0 parts)
             for win = (nth 1 parts)
             for pane = (nth 2 parts)
             when (and ptty win pane (string= ptty tty))
             return (cons win pane))))

(defun tmux-openfile--frame-tty (frame)
  "Return the TTY device path (e.g. /dev/pts/3) for FRAME, or nil.
Returns nil for GUI frames and for frames that are no longer live."
  (when (and frame (frame-live-p frame) (not (display-graphic-p frame)))
    (with-selected-frame frame
      (condition-case nil
          (terminal-name (frame-terminal nil))
        (error nil)))))

(defun tmux-openfile--open-spec (spec)
  "Open SPEC in the selected frame.

SPEC supports either:
- /path/to/file
- +LINE[:COLUMN] /path/to/file
"
  (let* ((s (string-trim spec))
         (re "\\`\\+\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?[[:space:]]+\\(.+\\)\\'"))
    (cond
     ((tmux-openfile--string-empty-p s)
      nil)
     ((string-match re s)
      (let* ((line (string-to-number (match-string 1 s)))
             (col (let ((m (match-string 2 s))) (and m (string-to-number m))))
             (file (match-string 3 s)))
        (find-file (expand-file-name file))
        (goto-char (point-min))
        (forward-line (max 0 (1- line)))
        (when (and col (> col 0))
          (move-to-column (1- col)))
        t))
     (t
      (find-file (expand-file-name s))
      t))))

(defun tmux-openfile--read-file (path)
  "Return the contents of PATH as a string, or nil if unreadable.
Used by the filenotify callback to read the file-spec written by et.zsh."
  (when (and (stringp path) (file-readable-p path))
    (with-temp-buffer
      (ignore-errors (insert-file-contents path))
      (buffer-string))))

(defun tmux-openfile--pane-for-frame (frame)
  "Return the tmux pane-id registered for FRAME, or nil."
  (cl-loop for pane being the hash-keys of tmux-openfile--pane->frame
           when (eq (gethash pane tmux-openfile--pane->frame) frame)
           return pane))

(defun tmux-openfile--install-watch (pane cmdfile)
  "Install a filenotify watch on CMDFILE for PANE.
When the watch fires, reads CMDFILE and opens the file-spec it contains in
the frame registered for PANE.  Does nothing if a watch already exists
for PANE."
  (when (and (file-exists-p cmdfile)
             (not (gethash pane tmux-openfile--pane->watch)))
    (puthash
     pane
     (file-notify-add-watch
      cmdfile
      tmux-openfile-watch-events
      (lambda (_event)
        (let* ((frame (gethash pane tmux-openfile--pane->frame))
               (spec (tmux-openfile--read-file cmdfile)))
          (when (and frame (frame-live-p frame) (stringp spec))
            (with-selected-frame frame
              (ignore-errors (tmux-openfile--open-spec spec)))))))
     tmux-openfile--pane->watch)))

(defun tmux-openfile--deregister-all ()
  "Deregister all sessions owned by this Emacs process.
Called from `kill-emacs-hook' so that stack entries are cleaned up even
when Emacs terminates without deleting individual frames first."
  (maphash
   (lambda (pane session)
     (let* ((win (car session))
            (cmdfile (cdr session))
            (stack (tmux-openfile--stack-read win))
            (new-stack (cl-remove cmdfile stack :test #'string=)))
       (tmux-openfile--stack-write win new-stack)
       (when-let ((watch (gethash pane tmux-openfile--pane->watch)))
         (file-notify-rm-watch watch))
       (ignore-errors (delete-file cmdfile))))
   tmux-openfile--pane->session)
  (clrhash tmux-openfile--pane->frame)
  (clrhash tmux-openfile--pane->session)
  (clrhash tmux-openfile--pane->watch))

(defun tmux-openfile--deregister-frame (frame)
  "Remove this session from the ordered session list and clean up.
Called from `delete-frame-functions' when an Emacs frame is closed."
  (let ((pane (tmux-openfile--pane-for-frame frame)))
    (when pane
      (let* ((session (gethash pane tmux-openfile--pane->session))
             (win (car session))
             (cmdfile (cdr session))
             (stack (tmux-openfile--stack-read win))
             (new-stack (cl-remove cmdfile stack :test #'string=)))
        (tmux-openfile--stack-write win new-stack)
        (when-let ((watch (gethash pane tmux-openfile--pane->watch)))
          (file-notify-rm-watch watch))
        (ignore-errors (delete-file cmdfile))
        (remhash pane tmux-openfile--pane->watch)
        (remhash pane tmux-openfile--pane->frame)
        (remhash pane tmux-openfile--pane->session)))))

(defun tmux-openfile--register-frame ()
  "Register the current frame's tmux pane with a command file and file watch.
Called from `server-after-make-frame-hook' for daemon sessions, or directly
from `tmux-openfile-enable' for regular sessions.  Idempotent: does nothing
if this pane is already registered."
  (let* ((frame (selected-frame))
         (tty (tmux-openfile--frame-tty frame))
         (loc (and tty (tmux-openfile--lookup-tty tty)))
         (win (car loc))
         (pane (cdr loc)))
    (when (and (stringp win)
               (not (gethash pane tmux-openfile--pane->frame)))
      (let* ((cmdfile (tmux-openfile--make-cmdfile win pane))
             (stack (tmux-openfile--stack-read win)))
        (tmux-openfile--install-watch pane cmdfile)
        (puthash pane frame tmux-openfile--pane->frame)
        (puthash pane (cons win cmdfile) tmux-openfile--pane->session)
        (tmux-openfile--stack-write win (append stack (list cmdfile)))))))

;;;###autoload
(defun tmux-openfile-enable ()
  "Enable the tmux open-file bridge for tty Emacs frames.
Registers the current frame immediately (for regular non-daemon sessions),
and installs hooks so that every subsequent tty frame is automatically
registered and every closed frame is automatically deregistered."
  (interactive)
  (require 'server nil t)
  (require 'filenotify nil t)
  (add-hook 'server-after-make-frame-hook #'tmux-openfile--register-frame)
  (add-hook 'delete-frame-functions #'tmux-openfile--deregister-frame)
  (add-hook 'kill-emacs-hook #'tmux-openfile--deregister-all)
  ;; Register the initial frame for regular (non-daemon) Emacs sessions.
  ;; In daemon mode this is a no-op: no TTY frame exists yet at startup.
  (tmux-openfile--register-frame))

;;;###autoload
(defun tmux-openfile-disable ()
  "Disable the tmux open-file bridge.
Removes the registration and deregistration hooks; frames already registered
remain active until they are closed."
  (interactive)
  (remove-hook 'server-after-make-frame-hook #'tmux-openfile--register-frame)
  (remove-hook 'delete-frame-functions #'tmux-openfile--deregister-frame)
  (remove-hook 'kill-emacs-hook #'tmux-openfile--deregister-all))

(provide 'tmux-openfile)

;;; tmux-openfile.el ends here
