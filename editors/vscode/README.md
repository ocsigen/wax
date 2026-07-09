# Wax for Visual Studio Code

Syntax highlighting, formatting, diagnostics, and snippets for
[Wax](https://github.com/ocsigen/wax) (a Rust-like syntax for WebAssembly) in
`.wax` files and for WebAssembly text (`.wat`) files.

## Features

- **Formatting** with the Wax formatter itself, compiled to WebAssembly and run
  in-process, so it works the same in desktop and web VS Code with no separate
  install. Run "Format Document", or turn on "Format on Save"
  (`editor.formatOnSave`). Files with syntax errors are left untouched.
- **Diagnostics** as you type: syntax errors, type errors, and lints from the
  same toolchain are shown inline (squiggles) and in the Problems panel.
- **WebAssembly text (`.wat`)**: the same features apply to `.wat` files too:
  formatting, diagnostics, document outline, syntax highlighting, snippets, and
  comment/bracket handling, all from the same in-process toolchain and grammar.
- **Syntax highlighting** via a TextMate grammar covering the full language:
  keywords and control flow (`fn`, `let`, `do`, `loop`, `match`, `dispatch`,
  `try`/`catch`, the `br*` branch family, stack-switching, …), primitive and
  abstract heap types, references, numeric/char/string literals with escapes,
  labels (`'label`), attributes (`#[export = …]`, `#[if(…)]`, `#[likely]`, …),
  aggregate literals (`{point| …}`, `[bytes| …]`), qualified intrinsics
  (`v128::const_i32x4`, `i64::add128`), and method-style intrinsics.
- **Language configuration**: line/block comments, bracket matching and
  colorization, auto-closing pairs, and indentation rules. Single quotes are
  intentionally *not* auto-closed, because they introduce labels.
- **Snippets** for common constructs (functions, imports/exports, control flow,
  types, tags, memories).
