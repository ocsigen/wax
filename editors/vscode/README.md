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
- **Hover types** (`.wax`): hover over an expression to see its inferred type,
  read straight off the type-checker's typed tree. Hovering a name that is not
  an expression shows what it resolves to instead — a type reference shows the
  type's definition, an assignment target or global shows its type. Works
  mid-edit through the recovering parser even while other parts of the file have
  errors.
- **Inlay hints** (`.wax`): the inferred type is shown inline on each
  un-annotated `let` binding (e.g. `let x = 3` displays `x: i32`). Toggle them
  with the `editor.inlayHints.enabled` setting.
- **Go to definition** (`.wax`): jump from a use to its definition — a function,
  global, type, or tag; a `let`/parameter binding; or a block/loop label. Works
  through shadowing (a use resolves to the binding actually in scope).
- **Find all references / highlight** (`.wax`): from a use or a definition, list
  every occurrence of the symbol (Shift+F12), and highlight them in the file when
  the cursor is on one.
- **Rename** (`.wax`): rename a symbol (F2) across all its occurrences, resolving
  through shadowing. A punned struct field is expanded (`{p| x}` becomes
  `{p| x: new}`) so the struct's field is left intact; rename is declined when the
  cursor is not on a renameable symbol.
- **Completion** (`.wax`): suggests the names in scope — the module's functions,
  globals, types, and tags, the enclosing function's parameters and locals, and
  keywords — and, after `.`, the fields of a struct value (including chains like
  `l.a.x`) plus the value methods for the receiver (`clz`/`sqrt`/… on a number,
  `length` on an array, the SIMD ops on a `v128`, the load/store/management ops
  on a memory or table); after `::`, an intrinsic namespace's functions
  (`v128::`, `i64::`, `atomic::`). Works while the file is
  mid-edit.
- **Signature help** (`.wax`): while typing a call, shows the callee's signature
  with the active argument highlighted (functions, imported functions, and
  `ns::` intrinsics).
- **Convert / preview**: "Wax: Show compiled WAT" (in a `.wax` file) opens the
  compiled WebAssembly text in a read-only document beside the source, updating
  live as you edit; "Wax: Show as Wax" does the reverse from a `.wat` file. Both
  are on the editor toolbar and in the command palette.
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
