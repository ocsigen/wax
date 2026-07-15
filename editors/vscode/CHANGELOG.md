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
