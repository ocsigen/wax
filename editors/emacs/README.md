# Wax in Emacs

`wax-ts-mode` is a major mode built on Emacs's built-in tree-sitter support
(`treesit`, Emacs ≥ 29) and the [`tree-sitter-wax`](../../tree-sitter-wax/)
grammar.


## Install

Since `wax-ts-mode` requires Emacs 29+, you can install it directly from this repository using the built-in `use-package` and `package-vc`:

```elisp
(use-package wax-ts-mode
  :vc (:url "https://github.com/ocsigen/wax"
       :branch "main"
       :lisp-dir "editors/emacs")
  :custom
  (wax-ts-mode-indent-offset 4)
  :hook
  (wax-ts-mode . eglot-ensure))
```

Alternatively, you can manually put `wax-ts-mode.el` on your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/wax/editors/emacs")
(require 'wax-ts-mode)
```

Emacs requires a C compiler to build the tree-sitter parser. When you open a `.wax` file for the first time, `wax-ts-mode` will automatically prompt you to download and compile the grammar into `~/.emacs.d/tree-sitter/`.

Alternatively, you can manually install or update the grammar at any time by running:

`M-x wax-ts-install-grammar RET`

Opening a `.wax` file automatically selects `wax-ts-mode` (it adds itself to `auto-mode-alist`). Check the grammar is available with `M-: (treesit-ready-p 'wax)` → `t`.

## Language server

`wax lsp` is the built-in language server. Eglot (built into Emacs ≥ 29, the
same version `wax-ts-mode` needs) drives it for diagnostics, hover, go to
definition, go to type definition, find references, rename, completion, and
signature help:

```elisp
(add-hook 'wax-ts-mode-hook #'eglot-ensure)
```

`wax` must be on `exec-path`. Errors and warnings show inline through Flymake
(which Eglot manages), with the warning's `-W` name in the message. The
tree-sitter mode still provides highlighting, indentation, and `imenu`; the
server adds the language intelligence on top.

## Formatting

Because `wax lsp` natively supports document formatting, Eglot can format your code out of the box. To enable format on save universally:

```elisp
(add-hook 'wax-ts-mode-hook
          (lambda () (add-hook 'before-save-hook #'eglot-format-buffer nil t)))
```

(If you prefer not to use Eglot, `M-x wax-format-buffer` reformats the buffer by piping it through `wax format -f wax`. Override the command with `wax-format-command` if needed.)

## What you get

Syntax highlighting (font-lock up to `treesit-font-lock-level`), tree-sitter
indentation, `imenu` (functions and types), and `treesit`-based structural
navigation (`beginning-of-defun` / `end-of-defun` over functions).
