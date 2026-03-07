;;; tmux-openfile.el --- Emacs <-> tmux open-file bridge -*- lexical-binding: t; -*-

;; This module implements a simple "open file" bridge for tmux windows:
;; - A tty emacsclient frame registers a per-window command file path into a tmux
;;   window user option (default: @emacs_openfile_cmdfile).
;; - Emacs watches that command file (in-place edits) and opens the file named
;;   inside it.
;; - An external helper (e.g. et.zsh) updates the command file.

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
