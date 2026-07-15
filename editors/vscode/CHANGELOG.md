# Changelog

## Unreleased

- Hover types for `.wax`: hovering over an expression shows its inferred type,
  read off the type-checker's typed tree. Works through the recovering parser
  while other parts of the file still have errors.
- Inlay hints for `.wax`: the inferred type is shown inline on each un-annotated
  `let` binding (e.g. `let x = 3` shows `x: i32`).
- Fixed editor positions (diagnostics, outline, hover, inlay hints) drifting on
  lines that contain non-ASCII characters: columns are now counted in UTF-16
  code units, matching VS Code, instead of UTF-8 bytes.
- Go to definition for `.wax`: jump from a use to its definition (function,
  global, type, tag, `let`/parameter, or block/loop label), resolving through
  shadowing to the binding actually in scope.
- Hover extended to names that are not expressions: a type reference (e.g.
  `&point`) shows the type's definition, and an assignment target or global
  shows its type.
- Find all references and document highlight for `.wax`: from a use or a
  definition, list every occurrence of the symbol and highlight them in the file.
- Rename for `.wax`: rename a symbol across all its occurrences (F2), resolving
  through shadowing. A punned struct field is expanded (`{p| x}` to `{p| x: new}`)
  so the field is preserved; rename is declined off a renameable symbol.
- Fixed the `.wax` word pattern, which used Unicode property escapes (`\p{L}`)
  that VS Code compiles without the `u` flag, so ordinary letters were not
  recognized as word characters — auto-completion only triggered after `_`, and
  word selection was off. Now uses plain character ranges.
- Completion for `.wax`: suggests the names in scope (module functions, globals,
  types, tags; the enclosing function's parameters and locals) and keywords, and
  after `.` the fields of a struct value (including chained accesses), working
  even while the file is mid-edit. Each item shows its type / signature (e.g.
  `fn(a: i32) -> i32`) where the declaration gives one.
- Member completion after `.` now also offers the value methods that apply to
  the receiver: the numeric methods (`clz`, `sqrt`, `min`, …) on an integer or
  float value, `length` on an array, and the SIMD vector ops (`add_i32x4`,
  `extract_lane_s_i8x16`, `shuffle_i8x16`, …) on a `v128`. Each carries a method
  icon and its signature (e.g. `fn(f32) -> f32`), and struct fields now show
  their declared type (`i32`, `mut i32`, `&point`).
- Completion after `::` offers an intrinsic namespace's free functions —
  `v128::` (const constructors, `bitselect`), `i64::` (wide arithmetic) and
  `atomic::` (`fence`) — each with its signature.
- Value-method completion now also fires when the receiver is a flexible
  numeric literal, not only a concrete type: `(3).` offers both integer and
  float methods (the literal can still narrow either way), `(3.0).` the float
  methods. Signatures render by family (`fn() -> int`) for such a receiver.
- Member completion on a memory or table receiver: `mem.` offers the scalar
  loads/stores, `size`/`grow`/`fill`/`copy`/`init`, and the atomic
  (`i32_atomic_load`, …) and SIMD (`v128_load`, …) memory accesses; `tab.` the
  management ops. Each carries its signature.
- Local completions are now scoped to the cursor: a `let` is offered only after
  it is bound and only within its block, so a local declared later in the
  function, or inside a sibling block, no longer appears. Parameters are always
  offered.
- The intrinsic namespace names (`v128`, `i64`, `atomic`) are offered in general
  completion, so the `::` intrinsics are discoverable.
- Completion respects conditional compilation: a definition in a `#[if]`/`#[else]`
  branch is offered only where its condition is compatible with the cursor's, so
  an `#[else]` function is not suggested while editing the matching `#[if]`
  branch (even when the branch is an `#[if]` inside a function body). With
  `wax.define` set, that configuration is fed in as an extra assumption
  (mirroring `-D`), so a definition in a branch the defines rule out is not
  offered at all.
- Signature help for `.wax`: while typing a call, the callee's signature is
  shown with the active argument highlighted — for functions, imported
  functions, `ns::` intrinsics, and methods (`x.min(…)`, `v.add_i32x4(…)`,
  `mem.load8(…)`, `tab.grow(…)`, `arr.fill(…)`), whose signature comes from the
  receiver's type. Triggers on `(` and `,`.
- Member completion on an array receiver now offers the bulk operations
  `fill`/`copy`/`init` alongside `length` (previously only `length`).
- Semantic highlighting for `.wax`: identifiers are coloured by role —
  functions, parameters, locals/globals, types (including type references like
  `&point`), struct fields, and intrinsic namespaces — beyond what the grammar
  can distinguish.
- Conditional-compilation dimming for `.wax`: set `wax.define` (mirroring `-D`,
  e.g. `["debug=true"]`) and the `#[if]`/`#[else]` branches that configuration
  makes unreachable are greyed out as dead code. A status-bar item shows the
  active defines when a `.wax` file is focused; clicking it (or the "Wax:
  Configure conditional-compilation defines" command) edits them.
- Diagnostics for `.wax` now specialize to the `wax.define` configuration
  (mirroring `wax -D … check`): the `#[if]`/`#[else]` branches that set rules out
  are dropped before type-checking, so a type error confined to an inactive
  branch no longer shows and the Problems match what a `-D` build sees. A partial
  set leaves the remaining `#[if]`s for the all-configurations check.

## 0.2.2

- Large `.wat` / `.wax` files now format in the editor; a non-tail recursion in
  the formatter previously overflowed the (small) wasm call stack on big modules,
  which just silently did nothing.
- Formatting now reports in the status bar when it cannot format a file (e.g. a
  syntax error) instead of silently doing nothing.
- The WAT / Wax preview keeps the last successful conversion (marked stale) while
  the source is temporarily invalid, instead of blanking to an error.

## 0.2.1

- Fix "Show compiled WAT" / "Show as Wax" failing to open on the web host
  (vscode.dev) for untitled or in-memory files.

## 0.2.0

- Formatting: reformat `.wax` files with the Wax formatter, compiled to
  WebAssembly and run in-process. Works via "Format Document" and "Format on
  Save", in both the desktop and web extension hosts. A file that fails to parse
  is left unchanged.
- Diagnostics: syntax errors, type errors, and lints from the toolchain are
  reported inline as you type (and in the Problems panel).
- Convert / preview: "Wax: Show compiled WAT" (from a `.wax` file) and "Wax:
  Show as Wax" (from a `.wat` file) open the conversion in a live read-only
  document beside the source.
- WebAssembly text (`.wat`): `.wat` files now get the same treatment as Wax:
  formatting, diagnostics, document outline, syntax highlighting (the grammar
  the documentation already used), snippets, and comment/bracket handling.
- The extension is declared safe in untrusted and virtual workspaces (the
  formatter only reads the buffer), so highlighting and formatting keep working
  without trusting the workspace. Load failures go to a "Wax" output channel.

## 0.1.2

- Follow the new import syntax: imports are written as `import "module" { … }`
  blocks (or the one-line `import "module" <declaration>;` form), replacing the
  old `#[import = ("module", "name")]` attribute. `import` is now highlighted as
  a keyword, and the `import` snippet expands to a block.

## 0.1.1

- Marketplace packaging: extension icon, gallery banner, and metadata
  (publisher, repository, and issue-tracker URLs).
- Highlight sigil reference types (`&fn`, `&?func`, `&Point`, …).

## 0.1.0

- Initial release: TextMate grammar and language configuration for Wax
  (`.wax` files), plus a small snippet set.
