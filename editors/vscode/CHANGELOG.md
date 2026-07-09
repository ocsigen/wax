# Changelog

## 0.2.2

- Formatting a file with syntax errors now says so in the status bar instead of
  doing nothing (the errors themselves are shown as squiggles / in Problems).

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
