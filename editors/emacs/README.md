# Wax in Emacs

`wax-ts-mode` is a major mode built on Emacs's built-in tree-sitter support
(`treesit`, Emacs ≥ 29) and the [`tree-sitter-wax`](../../tree-sitter-wax/)
grammar.

Emacs does **not** read the grammar's `.scm` query files — font-lock is defined
in Elisp inside `wax-ts-mode.el`, so this integration is a self-contained
package.

## Install

Put `wax-ts-mode.el` on your `load-path`, then register and build the grammar.
Emacs compiles the C parser itself (you need a C compiler):

```elisp
(add-to-list 'load-path "/path/to/wax/editors/emacs")
(require 'wax-ts-mode)

(add-to-list 'treesit-language-source-alist
             '(wax "https://github.com/ocsigen/wax" "main" "tree-sitter-wax/src"))
;; M-x treesit-install-language-grammar RET wax RET   (once)
```

`treesit-install-language-grammar` clones the repo and builds
`libtree-sitter-wax` into `~/.emacs.d/tree-sitter/`. Opening a `.wax` file then
selects `wax-ts-mode` (it adds itself to `auto-mode-alist`).

Check the grammar is available with `M-: (treesit-ready-p 'wax)` → `t`.

## Language server

`wax lsp` is the built-in language server. Eglot (built into Emacs ≥ 29, the
same version `wax-ts-mode` needs) drives it for diagnostics, hover, go to
definition, go to type definition, find references, rename, completion, and
signature help:

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(wax-ts-mode . ("wax" "lsp"))))

(add-hook 'wax-ts-mode-hook #'eglot-ensure)
```

`wax` must be on `exec-path`. Errors and warnings show inline through Flymake
(which Eglot manages), with the warning's `-W` name in the message. The
tree-sitter mode still provides highlighting, indentation, and `imenu`; the
server adds the language intelligence on top.

## Formatting

`M-x wax-format-buffer` reformats the buffer by piping it through
`wax format -f wax` (stdin → stdout). On a parse error the buffer is left
unchanged and the diagnostic is shown in the echo area. `wax` must be on
`exec-path`; override the command with `wax-format-command` if needed.

Format on save:

```elisp
(add-hook 'wax-ts-mode-hook
          (lambda () (add-hook 'before-save-hook #'wax-format-buffer nil t)))
```

## What you get

Syntax highlighting (font-lock up to `treesit-font-lock-level`), tree-sitter
indentation, `imenu` (functions and types), and `treesit`-based structural
navigation (`beginning-of-defun` / `end-of-defun` over functions).
