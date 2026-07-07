# Wax for Visual Studio Code

Syntax highlighting, bracket matching, and snippets for
[Wax](https://github.com/ocsigen/wax) — a Rust-like syntax for
WebAssembly — in `.wax` files.

## Features

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
