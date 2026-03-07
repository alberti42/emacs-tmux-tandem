# First release

## Features

- **Open files in Emacs from anywhere in tmux.** Run `et file.c` in any shell
  pane and the file opens instantly in your Emacs session — no copy-pasting
  paths, no switching windows manually.

- **Jump to a line or column.** Pass `+LINE` or `+LINE:COLUMN` before the
  filename to land exactly where you need to be.

- **Focus follows the file.** After opening, focus moves automatically to the
  Emacs pane. Use `-k` / `--keep-focus` to stay in the current pane instead.

- **Works with both regular Emacs and the Emacs daemon.** Whether you start
  Emacs directly with `emacs -nw` or connect via `emacsclient -t`, the bridge
  registers your session automatically.

- **zsh and bash support.** Install as a shell plugin (recommended) for
  zero-cost lazy loading, or drop the script directly on your `$PATH`.

- **Follows the `e` / `eg` / `et` alias convention.** Pairs naturally with
  `alias e='emacsclient -nw'` and `alias eg='emacsclient -n -c'` for a
  consistent Emacs-from-the-terminal workflow.
