;;; tmux-openfile.el --- Emacs <-> tmux open-file bridge -*- lexical-binding: t; -*-

;; Overview
;; --------
;; Lets shell tools ask a running Emacs server to open a file by writing a
;; file-spec into a small per-window IPC file that Emacs watches with filenotify.
;; Requires Emacs 29+ (server-after-make-frame-hook).
;;
;; Frame registration flow (emacsclient -t)
;; -----------------------------------------
;;
;;   emacsclient -t   →  server creates a TTY frame
;;                    →  server-after-make-frame-hook fires (normal hook, no args;
;;                           new frame is selected)
;;                    →  tmux-openfile--register-frame runs, calls (selected-frame)
;;                    →  tmux-openfile--frame-tty: is it a TTY? (display-graphic-p check)
;;                           GUI → returns nil → stops here, nothing happens
;;                           TTY → returns the /dev/pts/N path
;;                    →  tmux-openfile--lookup-tty: runs `tmux list-panes -a'
;;                           to find which window/pane owns that /dev/pts/N
;;                           not in tmux → returns nil → stops here
;;                           in tmux → returns (window_id . pane_id) e.g. (@3 . %5)
;;                    →  tmux-openfile--ensure-cmdfile: creates the IPC file
;;                           at $XDG_CACHE_HOME/emacs/tmux-openfile/openfile-@3.cmd
;;                    →  tmux set-option -w -t @3 @emacs_openfile_cmdfile <path>
;;                    →  tmux set-option -w -t @3 @emacs_openfile_paneid %5
;;                    →  tmux-openfile--install-watch: installs filenotify watch on that file
;;
;; Frame deregistration flow (emacsclient exits)
;; -----------------------------------------------
;;
;;   frame deleted    →  delete-frame-functions fires with that frame
;;                    →  tmux-openfile--deregister-frame runs
;;                    →  reverse-lookup finds the window-id for the frame
;;                    →  tmux set-option -w -t @3 -u @emacs_openfile_cmdfile
;;                    →  tmux set-option -w -t @3 -u @emacs_openfile_paneid
;;                    →  file-notify-rm-watch removes the IPC file watch
;;                    →  frame and watch entries removed from internal tables
;;                    →  et.zsh will now report no Emacs client in this window
;;
;; Open-file flow (et.zsh → Emacs)
;; --------------------------------
;;
;;   et.zsh FILE      →  reads @emacs_openfile_cmdfile from the current tmux window
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
;; automatic for every subsequent tty emacsclient frame.
;; Call `tmux-openfile-disable' to stop registering new frames.

(require 'cl-lib)

(defgroup tmux-openfile nil
  "Open files in Emacs via tmux window metadata."
  :group 'external)

(defcustom tmux-openfile-tmux-option "@emacs_openfile_cmdfile"
  "tmux window user option that stores the command file path."
  :type 'string)

(defcustom tmux-openfile-pane-option "@emacs_openfile_paneid"
  "tmux window user option that stores the Emacs pane ID."
  :type 'string)

(defcustom tmux-openfile-cache-subdir "tmux-emacs-openfile"
  "Subdirectory under XDG cache for command files."
  :type 'string)

(defcustom tmux-openfile-watch-events '(change)
  "Events passed to `file-notify-add-watch'."
  :type '(repeat symbol))

(defvar tmux-openfile--win->watch (make-hash-table :test 'equal))
(defvar tmux-openfile--win->frame (make-hash-table :test 'equal))

(defun tmux-openfile--string-empty-p (s)
  (or (null s) (= (length s) 0)))

(defun tmux-openfile--xdg-cache-home ()
  (let ((d (or (getenv "XDG_CACHE_HOME")
               (expand-file-name "~/.cache"))))
    (file-name-as-directory (expand-file-name d))))

(defun tmux-openfile--cache-dir ()
  (expand-file-name tmux-openfile-cache-subdir (tmux-openfile--xdg-cache-home)))

(defun tmux-openfile--sanitize-for-filename (s)
  (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" (or s "")))

(defun tmux-openfile--ensure-cmdfile (window-id)
  (let* ((dir (tmux-openfile--cache-dir))
         (leaf (format "openfile-%s.cmd" (tmux-openfile--sanitize-for-filename window-id)))
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
  "Return tty path string for FRAME, or nil."
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
  (when (and (stringp path) (file-readable-p path))
    (with-temp-buffer
      (ignore-errors (insert-file-contents path))
      (buffer-string))))

(defun tmux-openfile--win-for-frame (frame)
  "Return the tmux window-id registered for FRAME, or nil."
  (cl-loop for win being the hash-keys of tmux-openfile--win->frame
           when (eq (gethash win tmux-openfile--win->frame) frame)
           return win))

(defun tmux-openfile--install-watch (window-id cmdfile)
  (when (and (file-exists-p cmdfile)
             (not (gethash window-id tmux-openfile--win->watch)))
    (puthash
     window-id
     (file-notify-add-watch
      cmdfile
      tmux-openfile-watch-events
      (lambda (_event)
        (let* ((frame (gethash window-id tmux-openfile--win->frame))
               (spec (tmux-openfile--read-file cmdfile)))
          (when (and frame (frame-live-p frame) (stringp spec))
            (with-selected-frame frame
              (ignore-errors (tmux-openfile--open-spec spec)))))))
     tmux-openfile--win->watch)))

(defun tmux-openfile--deregister-frame (frame)
  "Unset tmux window variables and remove the file watch for FRAME.
Called from `delete-frame-functions' when an emacsclient frame is closed."
  (let ((win (tmux-openfile--win-for-frame frame)))
    (when win
      (tmux-openfile--tmux "set-option" "-w" "-t" win "-u" tmux-openfile-tmux-option)
      (tmux-openfile--tmux "set-option" "-w" "-t" win "-u" tmux-openfile-pane-option)
      (when-let ((watch (gethash win tmux-openfile--win->watch)))
        (file-notify-rm-watch watch))
      (remhash win tmux-openfile--win->watch)
      (remhash win tmux-openfile--win->frame))))

(defun tmux-openfile--register-frame ()
  "Register the current frame's tmux window with a command file and file watch.
Called from `server-after-make-frame-hook', where the new frame is selected."
  (let* ((frame (selected-frame))
         (tty (tmux-openfile--frame-tty frame))
         (loc (and tty (tmux-openfile--lookup-tty tty)))
         (win (car loc))
         (pane (cdr loc)))
    (when (stringp win)
      (puthash win frame tmux-openfile--win->frame)
      (let ((cmdfile (tmux-openfile--ensure-cmdfile win)))
        (tmux-openfile--tmux "set-option" "-w" "-t" win tmux-openfile-tmux-option cmdfile)
        (tmux-openfile--tmux "set-option" "-w" "-t" win tmux-openfile-pane-option pane)
        (tmux-openfile--install-watch win cmdfile)))))

;;;###autoload
(defun tmux-openfile-enable ()
  "Enable tmux openfile registration for tty emacsclient frames." 
  (interactive)
  (require 'server nil t)
  (require 'filenotify nil t)
  (add-hook 'server-after-make-frame-hook #'tmux-openfile--register-frame)
  (add-hook 'delete-frame-functions #'tmux-openfile--deregister-frame))

;;;###autoload
(defun tmux-openfile-disable ()
  "Disable tmux openfile registration hook." 
  (interactive)
  (remove-hook 'server-after-make-frame-hook #'tmux-openfile--register-frame)
  (remove-hook 'delete-frame-functions #'tmux-openfile--deregister-frame))

(provide 'tmux-openfile)

;;; tmux-openfile.el ends here
