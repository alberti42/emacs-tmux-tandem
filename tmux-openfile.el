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
;;                    →  server-after-make-frame-hook fires with that frame
;;                    →  tmux-openfile--register-frame runs
;;                    →  tmux-openfile--frame-tty: is it a TTY? (display-graphic-p check)
;;                           GUI → returns nil → stops here, nothing happens
;;                           TTY → returns the /dev/pts/N path
;;                    →  tmux-openfile--window-id-for-tty: runs `tmux list-panes -a'
;;                           to find which window owns that /dev/pts/N
;;                           not in tmux → returns nil → stops here
;;                           in tmux → returns window_id (e.g. @3)
;;                    →  tmux-openfile--ensure-cmdfile: creates the IPC file
;;                           at $XDG_CACHE_HOME/emacs/tmux-openfile/openfile-@3.cmd
;;                    →  tmux set-option -w -t @3 @emacs_openfile_cmdfile <path>
;;                    →  tmux-openfile--install-watch: installs filenotify watch on that file
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

(defun tmux-openfile--window-id-for-tty (tty)
  "Return tmux window_id whose pane_tty equals TTY (string), or nil."
  (let* ((out (tmux-openfile--tmux "list-panes" "-a" "-F" "#{pane_tty}\t#{window_id}"))
         (lines (and out (split-string out "\n" t))))
    (cl-loop for line in lines
             for parts = (split-string line "\t")
             for ptty = (nth 0 parts)
             for win = (nth 1 parts)
             when (and ptty win (string= ptty tty))
             return win)))

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

(defun tmux-openfile--register-frame (frame)
  "Register FRAME's tmux window with a command file and file watch." 
  (let* ((tty (tmux-openfile--frame-tty frame))
         (win (and tty (tmux-openfile--window-id-for-tty tty))))
    (when (stringp win)
      (puthash win frame tmux-openfile--win->frame)
      (let ((cmdfile (tmux-openfile--ensure-cmdfile win)))
        (tmux-openfile--tmux "set-option" "-w" "-t" win tmux-openfile-tmux-option cmdfile)
        (tmux-openfile--install-watch win cmdfile)))))

;;;###autoload
(defun tmux-openfile-enable ()
  "Enable tmux openfile registration for tty emacsclient frames." 
  (interactive)
  (require 'server nil t)
  (require 'filenotify nil t)
  (add-hook 'server-after-make-frame-hook #'tmux-openfile--register-frame))

;;;###autoload
(defun tmux-openfile-disable ()
  "Disable tmux openfile registration hook." 
  (interactive)
  (remove-hook 'server-after-make-frame-hook #'tmux-openfile--register-frame))

(provide 'tmux-openfile)

;;; tmux-openfile.el ends here
