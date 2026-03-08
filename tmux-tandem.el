;;; tmux-tandem.el --- Emacs <-> tmux bridge -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; URL: https://github.com/alberti42/emacs-tmux-tandem
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, terminals

;; Overview
;; --------
;; Lets shell tools ask a running Emacs to open a file by writing a file-spec
;; into a small per-window IPC file that Emacs watches with filenotify.
;; Requires Emacs 29+ (server-after-make-frame-hook).
;;
;; Works with both session types:
;;   - Regular Emacs (emacs -nw): the initial TTY frame is registered immediately
;;     when `tmux-tandem-enable' is called from init.el.
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
;;   Emacs TTY frame  →  tmux-tandem--register-frame runs (either immediately
;;     appears            on enable, or via server-after-make-frame-hook)
;;                    →  tmux-tandem--frame-tty: is it a TTY? (display-graphic-p check)
;;                           GUI → returns nil → stops here, nothing happens
;;                           TTY → returns the /dev/pts/N path
;;                    →  tmux-tandem--lookup-tty: runs `tmux list-panes -a'
;;                           to find which window/pane owns that /dev/pts/N
;;                           not in tmux → returns nil → stops here
;;                           in tmux → returns (window_id . pane_id) e.g. (@3 . %5)
;;                    →  guard: pane already registered? → stop (idempotent)
;;                    →  tmux-tandem--make-cmdfile: creates the IPC file
;;                           at $XDG_CACHE_HOME/emacs/tmux-tandem/openfile-<win>-<pane>.cmd
;;                    →  append cmdfile path to @emacs_openfile_stack
;;                    →  tmux-tandem--install-watch: installs filenotify watch on that file
;;
;; Frame deregistration flow
;; -------------------------
;;
;;   Emacs frame      →  delete-frame-functions fires with that frame
;;     closed         →  tmux-tandem--deregister-frame runs
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
;;                    →  reads the IPC file and calls tmux-tandem--open-spec
;;                    →  find-file opens the file in the registered frame
;;
;; File-spec format
;; ----------------
;;   /path/to/file
;;   +LINE[:COLUMN] /path/to/file
;;
;; Usage
;; -----
;; Call `tmux-tandem-enable' once (e.g. from init.el).  Registration is then
;; automatic for every subsequent tty frame.
;; Call `tmux-tandem-disable' to stop registering new frames.

(require 'cl-lib)

(defgroup tmux-tandem nil
  "Open files in Emacs via tmux window metadata."
  :group 'external)

(defcustom tmux-tandem-cache-subdir "tmux-tandem"
  "Subdirectory under $XDG_CACHE_HOME/emacs/ for IPC command files."
  :type 'string)

(defcustom tmux-tandem-watch-events '(change)
  "Events passed to `file-notify-add-watch'."
  :type '(repeat symbol))

(defcustom tmux-tandem-stack-option "@emacs_openfile_stack"
  "tmux window user option that stores the ordered session list (leftmost = active)."
  :type 'string)

;; All three tables are keyed by pane-id (e.g. "%5"), which is unique per
;; session even when multiple sessions share the same tmux window.
(defvar tmux-tandem--pane->frame (make-hash-table :test 'equal)
  "Hash table: pane-id → frame for this Emacs process.")

(defvar tmux-tandem--pane->session (make-hash-table :test 'equal)
  "Hash table: pane-id → (win . cmdfile) for this Emacs process's session.")

(defvar tmux-tandem--pane->watch (make-hash-table :test 'equal)
  "Hash table: pane-id → filenotify watch descriptor for this process's cmdfile.")

(defun tmux-tandem--string-empty-p (s)
  "Return t if S is nil or the empty string."
  (or (null s) (= (length s) 0)))

(defun tmux-tandem--xdg-cache-home ()
  "Return the XDG cache home directory with a trailing slash.
Uses $XDG_CACHE_HOME if set, otherwise falls back to ~/.cache."
  (let ((d (or (getenv "XDG_CACHE_HOME")
               (expand-file-name "~/.cache"))))
    (file-name-as-directory (expand-file-name d))))

(defun tmux-tandem--cache-dir ()
  "Return the absolute path to the IPC file cache directory.
Resolves to $XDG_CACHE_HOME/emacs/`tmux-tandem-cache-subdir'."
  (expand-file-name tmux-tandem-cache-subdir
                    (expand-file-name "emacs" (tmux-tandem--xdg-cache-home))))

(defun tmux-tandem--make-cmdfile (window-id pane-id)
  "Return the IPC file path for WINDOW-ID and PANE-ID, creating it if necessary.
Named openfile-<window_id>-<pane_id>.cmd (e.g. openfile-@3-%5.cmd).
The file and its parent directory are created with 0700/0600 permissions."
  (let* ((dir (tmux-tandem--cache-dir))
         (leaf (format "openfile-%s-%s.cmd" window-id pane-id))
         (path (expand-file-name leaf dir)))
    (unless (file-directory-p dir)
      (make-directory dir t)
      (ignore-errors (set-file-modes dir #o700)))
    (unless (file-exists-p path)
      (with-temp-buffer (write-region "" nil path nil 'silent))
      (ignore-errors (set-file-modes path #o600)))
    path))

(defvar tmux-tandem--executable (executable-find "tmux")
  "Cached path to the tmux executable, or nil if not found.")

(defun tmux-tandem--tmux (&rest args)
  "Run tmux ARGS. Return stdout string on success, nil otherwise."
  (when tmux-tandem--executable
    (with-temp-buffer
      (let ((rc (apply #'call-process tmux-tandem--executable nil t nil args)))
        (when (and (numberp rc) (zerop rc))
          (buffer-string))))))

(defun tmux-tandem--stack-read (win)
  "Return the session stack for tmux window WIN as a list of strings.
Each entry is a cmdfile path; leftmost is the active session.  Returns nil if unset."
  (let ((raw (tmux-tandem--tmux "show-options" "-w" "-qv" "-t" win
                                  tmux-tandem-stack-option)))
    (if (or (null raw) (string-empty-p (string-trim raw)))
        nil
      (split-string (string-trim raw) "\x1f" t))))

(defun tmux-tandem--stack-write (win entries)
  "Write ENTRIES (list of strings) back to the stack tmux option for WIN.
Unsets the option if ENTRIES is empty."
  (if entries
      (tmux-tandem--tmux "set-option" "-w" "-t" win
                           tmux-tandem-stack-option
                           (mapconcat #'identity entries "\x1f"))
    (tmux-tandem--tmux "set-option" "-w" "-t" win "-u"
                         tmux-tandem-stack-option)))

(defun tmux-tandem--lookup-tty (tty)
  "Return a cons (WINDOW-ID . PANE-ID) for the tmux pane whose tty equals TTY, or nil."
  (let* ((out (tmux-tandem--tmux "list-panes" "-a" "-F" "#{pane_tty}\t#{window_id}\t#{pane_id}"))
         (lines (and out (split-string out "\n" t))))
    (cl-loop for line in lines
             for parts = (split-string line "\t")
             for ptty = (nth 0 parts)
             for win = (nth 1 parts)
             for pane = (nth 2 parts)
             when (and ptty win pane (string= ptty tty))
             return (cons win pane))))

(defun tmux-tandem--frame-tty (frame)
  "Return the TTY device path (e.g. /dev/pts/3) for FRAME, or nil.
Returns nil for GUI frames and for frames that are no longer live."
  (when (and frame (frame-live-p frame) (not (display-graphic-p frame)))
    (with-selected-frame frame
      (condition-case nil
          (terminal-name (frame-terminal nil))
        (error nil)))))

(defun tmux-tandem--open-spec (spec)
  "Open SPEC in the selected frame.

SPEC supports either:
- /path/to/file
- +LINE[:COLUMN] /path/to/file
"
  (let* ((s (string-trim spec))
         (re "\\`\\+\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?[[:space:]]+\\(.+\\)\\'"))
    (cond
     ((tmux-tandem--string-empty-p s)
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

(defun tmux-tandem--read-file (path)
  "Return the contents of PATH as a string, or nil if unreadable.
Used by the filenotify callback to read the file-spec written by et.zsh."
  (when (and (stringp path) (file-readable-p path))
    (with-temp-buffer
      (ignore-errors (insert-file-contents path))
      (buffer-string))))

(defun tmux-tandem--pane-for-frame (frame)
  "Return the tmux pane-id registered for FRAME, or nil."
  (cl-loop for pane being the hash-keys of tmux-tandem--pane->frame
           when (eq (gethash pane tmux-tandem--pane->frame) frame)
           return pane))

(defun tmux-tandem--install-watch (pane cmdfile)
  "Install a filenotify watch on CMDFILE for PANE.
When the watch fires, reads CMDFILE and opens the file-spec it contains in
the frame registered for PANE.  Does nothing if a watch already exists
for PANE."
  (when (and (file-exists-p cmdfile)
             (not (gethash pane tmux-tandem--pane->watch)))
    (puthash
     pane
     (file-notify-add-watch
      cmdfile
      tmux-tandem-watch-events
      (lambda (_event)
        (let* ((frame (gethash pane tmux-tandem--pane->frame))
               (spec (tmux-tandem--read-file cmdfile)))
          (when (and frame (frame-live-p frame) (stringp spec))
            (with-selected-frame frame
              (ignore-errors (tmux-tandem--open-spec spec)))))))
     tmux-tandem--pane->watch)))

(defun tmux-tandem--deregister-all ()
  "Deregister all sessions owned by this Emacs process.
Called from `kill-emacs-hook' so that stack entries are cleaned up even
when Emacs terminates without deleting individual frames first."
  (maphash
   (lambda (pane session)
     (let* ((win (car session))
            (cmdfile (cdr session))
            (stack (tmux-tandem--stack-read win))
            (new-stack (cl-remove cmdfile stack :test #'string=)))
       (tmux-tandem--stack-write win new-stack)
       (when-let ((watch (gethash pane tmux-tandem--pane->watch)))
         (file-notify-rm-watch watch))
       (ignore-errors (delete-file cmdfile))))
   tmux-tandem--pane->session)
  (clrhash tmux-tandem--pane->frame)
  (clrhash tmux-tandem--pane->session)
  (clrhash tmux-tandem--pane->watch))

(defun tmux-tandem--deregister-frame (frame)
  "Remove this session from the ordered session list and clean up.
Called from `delete-frame-functions' when an Emacs frame is closed."
  (let ((pane (tmux-tandem--pane-for-frame frame)))
    (when pane
      (let* ((session (gethash pane tmux-tandem--pane->session))
             (win (car session))
             (cmdfile (cdr session))
             (stack (tmux-tandem--stack-read win))
             (new-stack (cl-remove cmdfile stack :test #'string=)))
        (tmux-tandem--stack-write win new-stack)
        (when-let ((watch (gethash pane tmux-tandem--pane->watch)))
          (file-notify-rm-watch watch))
        (ignore-errors (delete-file cmdfile))
        (remhash pane tmux-tandem--pane->watch)
        (remhash pane tmux-tandem--pane->frame)
        (remhash pane tmux-tandem--pane->session)))))

(defun tmux-tandem--register-frame ()
  "Register the current frame's tmux pane with a command file and file watch.
Called from `server-after-make-frame-hook' for daemon sessions, or directly
from `tmux-tandem-enable' for regular sessions.  Idempotent: does nothing
if this pane is already registered."
  (let* ((frame (selected-frame))
         (tty (tmux-tandem--frame-tty frame))
         (loc (and tty (tmux-tandem--lookup-tty tty)))
         (win (car loc))
         (pane (cdr loc)))
    (when (and (stringp win)
               (not (gethash pane tmux-tandem--pane->frame)))
      (let* ((cmdfile (tmux-tandem--make-cmdfile win pane))
             (stack (tmux-tandem--stack-read win)))
        (tmux-tandem--install-watch pane cmdfile)
        (puthash pane frame tmux-tandem--pane->frame)
        (puthash pane (cons win cmdfile) tmux-tandem--pane->session)
        (tmux-tandem--stack-write win (append stack (list cmdfile)))))))

;;;###autoload
(defun tmux-tandem-enable ()
  "Enable the tmux bridge for tty Emacs frames.
Registers the current frame immediately (for regular non-daemon sessions),
and installs hooks so that every subsequent tty frame is automatically
registered and every closed frame is automatically deregistered."
  (interactive)
  (require 'server nil t)
  (require 'filenotify nil t)
  (add-hook 'server-after-make-frame-hook #'tmux-tandem--register-frame)
  (add-hook 'delete-frame-functions #'tmux-tandem--deregister-frame)
  (add-hook 'kill-emacs-hook #'tmux-tandem--deregister-all)
  ;; Register the initial frame for regular (non-daemon) Emacs sessions.
  ;; In daemon mode this is a no-op: no TTY frame exists yet at startup.
  (tmux-tandem--register-frame))

;;;###autoload
(defun tmux-tandem-disable ()
  "Disable the tmux bridge.
Removes all hooks and fully deregisters every session owned by this Emacs
process: stack entries are removed from @emacs_openfile_stack, filenotify
watches are cancelled, and cmdfiles are deleted from disk.

In a regular Emacs session this affects only the current session.
In a daemon session (emacs --daemon + emacsclient) this deregisters all
connected client frames across all tmux windows."
  (interactive)
  (remove-hook 'server-after-make-frame-hook #'tmux-tandem--register-frame)
  (remove-hook 'delete-frame-functions #'tmux-tandem--deregister-frame)
  (remove-hook 'kill-emacs-hook #'tmux-tandem--deregister-all)
  (tmux-tandem--deregister-all))

(provide 'tmux-tandem)

;;; tmux-tandem.el ends here
