# emacs-tmux-openfile

Open files in a running Emacs session from anywhere inside tmux — a single
shell command sends a file to Emacs and moves focus there instantly.

```zsh
et src/main.c          # open file, focus jumps to Emacs
et +42 src/main.c      # open at line 42
et +42:7 src/main.c    # open at line 42, column 7
et -k src/main.c       # open file, keep focus in the current pane
```

## How it works

When Emacs starts inside a tmux window, it registers itself by:

1. Creating a small IPC file under `$XDG_CACHE_HOME/emacs/tmux-openfile/`.
2. Storing the path to that file in a tmux window variable
   (`@emacs_openfile_cmdfile`) so that any shell in the same window can find it.
3. Watching the IPC file with Emacs's built-in `filenotify`.

When you run `et FILE`, the script reads the window variable, writes the
file path into the IPC file, and Emacs opens it immediately. When the Emacs
frame is closed the window variables are unset, so `et` reports a clear
error if no session is registered.

Works with both session types:

- **Regular Emacs** (`emacs -nw`): registered on startup.
- **Daemon + emacsclient** (`emacs --daemon` / `emacsclient -t`): registered
  automatically each time a new TTY frame is created. GUI frames are ignored.

## Requirements

- Emacs 29 or later
- tmux
- zsh or bash

## Installation

### 1. Install the Emacs module

Copy `tmux-openfile.el` somewhere on your `load-path`, then add to your
`init.el`:

```elisp
;; Requires Emacs 29+ for server-after-make-frame-hook.
(when (>= emacs-major-version 29)
  (require 'tmux-openfile)
  (tmux-openfile-enable))
```

If you use `straight.el`:

```elisp
(when (>= emacs-major-version 29)
  (use-package tmux-openfile
    :straight (tmux-openfile
               :type git
               :host github
               :repo "alberti42/emacs-tmux-openfile")
    :config
    (tmux-openfile-enable)))
```

### 2. Install the shell helper

The shell side is supported for both **zsh** and **bash**. There are two
installation options — choose whichever fits your setup.

#### Option A — Plugin (recommended)

The plugin defines a lazy-loading `et` function in your interactive shell.
The real implementation is sourced on the first call and the stub replaces
itself, so there is no measurable startup cost and no `PATH` changes are
needed.

**zsh** — source the plugin from `.zshrc`, or point any plugin manager at
the repository root:

```zsh
# .zshrc — manual
source /path/to/emacs-tmux-openfile/emacs-tmux-openfile.plugin.zsh
```

```zsh
# zinit
zinit light your-github-user/emacs-tmux-openfile

# oh-my-zsh (clone into custom plugins directory)
# plugins=(... emacs-tmux-openfile)
```

**bash** — source the plugin from `.bashrc`:

```bash
# .bashrc
source /path/to/emacs-tmux-openfile/emacs-tmux-openfile.plugin.bash
```

#### Option B — Script on PATH

`src/et.zsh` and `src/et.bash` can each be executed directly as standalone
scripts. Make the file executable and place a symlink somewhere on your
`$PATH`:

```zsh
# zsh
chmod +x /path/to/emacs-tmux-openfile/src/et.zsh
ln -s /path/to/emacs-tmux-openfile/src/et.zsh ~/.local/bin/et
```

```bash
# bash
chmod +x /path/to/emacs-tmux-openfile/src/et.bash
ln -s /path/to/emacs-tmux-openfile/src/et.bash ~/.local/bin/et
```

## Usage

```
et [-k] FILE
et --cmdfile
et --list
```

| Argument / Option    | Description                                                   |
| -------------------- | ------------------------------------------------------------- |
| `FILE`               | File to open. Accepts a plain path or `+LINE[:COL] path`.     |
| `-k`, `--keep-focus` | Open the file but do not move focus to the Emacs pane.        |
| `--cmdfile`          | Print the IPC file path for the current tmux window and exit. |
| `--list`             | List all tmux panes with their index, id, command, and tty.   |

### File-spec format

```
/absolute/or/relative/path
+LINE /path/to/file
+LINE:COLUMN /path/to/file
```

## Verifying the setup

After starting Emacs in a TTY inside tmux, check that registration succeeded:

```zsh
tmux show -w @emacs_openfile_cmdfile   # should print the IPC file path
tmux show -w @emacs_openfile_paneid    # should print the Emacs pane ID
```

If the variables are empty, confirm that `tmux` was found by Emacs at startup:

```
M-: tmux-openfile--executable
```

## Configuration

All options belong to the `tmux-openfile` customize group (`M-x customize-group
tmux-openfile`).

| Variable                     | Default                   | Description                                               |
| ---------------------------- | ------------------------- | --------------------------------------------------------- |
| `tmux-openfile-tmux-option`  | `@emacs_openfile_cmdfile` | tmux window option that stores the IPC file path          |
| `tmux-openfile-pane-option`  | `@emacs_openfile_paneid`  | tmux window option that stores the Emacs pane ID          |
| `tmux-openfile-cache-subdir` | `tmux-openfile`           | Subdirectory under `$XDG_CACHE_HOME/emacs/` for IPC files |
| `tmux-openfile-watch-events` | `(change)`                | filenotify events that trigger file opening               |

## License

See [LICENSE](LICENSE).
