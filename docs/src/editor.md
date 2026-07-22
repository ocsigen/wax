# Editor Support

Wax integrates with editors in two ways. **Visual Studio Code** has a dedicated
extension that bundles everything. Every other editor combines two pieces: the
[`tree-sitter-wax`](https://github.com/ocsigen/wax/tree/main/tree-sitter-wax)
grammar for syntax highlighting, and the built-in **`wax lsp`** language server
(see [CLI Reference](cli.md#language-server)) for everything else. The extension
and the server run the same analysis as the `wax` toolchain, so the language
features are the same across editors.

## Features

Available in VS Code, and in any editor with a Language Server Protocol client
through `wax lsp`:

- Diagnostics as you type: syntax errors, type errors, and lints.
- Hover types, and inlay hints showing the inferred type on each un-annotated
  `let` binding.
- Go to definition, go to type definition, find references, and document
  highlight.
- Rename (a punned struct field is expanded so the field is preserved).
- Completion: the names in scope, a struct value's fields and a numeric / array
  / `v128` / memory / table receiver's methods after `.`, and an intrinsic
  namespace's functions after `::`.
- Signature help while typing a call.
- Document outline, folding ranges, selection ranges, and semantic tokens.
- Formatting.

WebAssembly text (`.wat`) gets the same features: formatting,
diagnostics, the outline, hover types, go-to-definition, go-to-type-definition,
find references, document highlight, rename, folding, selection ranges, signature
help, semantic tokens (identifiers coloured by the kind of index they resolve
to), completion (where an index is expected, the names of the space it wants —
functions, globals, locals, types, labels — since the instruction fixes the
kind), inlay hints (after a numeric index, the name of the definition it
refers to, so `(local.get 0)` reads as `(local.get 0 $x)`), and inactive-branch
dimming for `(@if)` conditional compilation. Syntax highlighting
otherwise comes from the extension's own grammar in VS Code and from
`tree-sitter-wax` elsewhere.

## Visual Studio Code

The [Wax extension](https://marketplace.visualstudio.com/items?itemName=wax-wasm.wax)
(source in [`editors/vscode/`](https://github.com/ocsigen/wax/tree/main/editors/vscode))
covers both `.wax` and `.wat` files with the full feature set above, plus
snippets and commands to preview the compiled WAT or decompiled Wax side by
side. It runs the toolchain compiled to WebAssembly in-process, with no separate
`wax` install, so it works the same in desktop and web VS Code (including
[vscode.dev](https://vscode.dev)).

## Other editors

Any editor with a Language Server Protocol client gets the feature set above by
launching `wax lsp`. The editor starts the server itself, so `wax` only needs to
be on your `PATH`; pair it with the tree-sitter grammar for highlighting.
Ready-to-use configurations, each with a README, live under
[`editors/`](https://github.com/ocsigen/wax/tree/main/editors):

- **[Neovim](https://github.com/ocsigen/wax/blob/main/editors/nvim/README.md)**: register
  the `tree-sitter-wax` parser (nvim-treesitter or the built-in loader) and
  point `vim.lsp` at `wax lsp`.
- **[Helix](https://github.com/ocsigen/wax/blob/main/editors/helix/README.md)**: add the
  grammar and a `[language-server.wax]` entry running `wax lsp` (a ready-to-paste
  `languages.toml` is included).
- **[Emacs](https://github.com/ocsigen/wax/blob/main/editors/emacs/README.md)**:
  `wax-ts-mode` provides tree-sitter highlighting, indentation, and `imenu`,
  with Eglot driving `wax lsp` for the rest. Requires Emacs 29+ and can be installed directly from GitHub using `use-package` with `package-vc`:

  ```elisp
  (use-package wax-ts-mode
    :vc (:url "https://github.com/ocsigen/wax"
         :branch "main"
         :rev :newest
         :lisp-dir "editors/emacs")
    :hook (wax-ts-mode . eglot-ensure))

  ;; Optional: completion popup as you type. Without it, Eglot still serves
  ;; completions through the built-in `completion-at-point' (C-M-i).
  (use-package corfu
    :ensure t
    :custom
    (corfu-auto t)
    (corfu-auto-prefix 1)  ; pop up after one character, not the default 3
    :hook (wax-ts-mode . corfu-mode))
  ```

The server's flags and behaviour (document sync, position-encoding negotiation)
are documented under [`wax lsp`](cli.md#language-server) in the CLI reference.

## AI coding agents

Coding assistants that support the `SKILL.md` agent-skill format (Claude Code,
Antigravity, Copilot, Codex, ...) can be taught Wax with the
[`wax` skill](https://github.com/ocsigen/wax/tree/main/skills/wax) shipped in
the repository. Wax has almost no presence in model training data, so the
skill bundles the complete language reference as a single context-loadable
file and instructs the agent to validate everything it writes with
`wax check`. Install it with the
[`skills` CLI](https://github.com/vercel-labs/skills):

```sh
npx skills add ocsigen/wax
```

or copy `skills/wax/` into the agent's skills directory (for Claude Code,
`.claude/skills/`).
