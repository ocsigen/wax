# Wax VS Code extension: possible additions

Ideas for extending the extension, grouped by effort. The bias is toward
features that reuse what the toolchain already computes (parse, type-check with
diagnostics/hints, format, and full wax/wat/wasm conversion) rather than new
analysis.

## Current features

- Syntax highlighting (TextMate grammar), bracket matching, snippets.
- Formatting (Format Document, Format on Save), the toolchain compiled to wasm
  and run in-process, in both the desktop and web hosts.
- Diagnostics as you type: syntax errors, type errors, and lints, via a
  `check(src)` export that parses (`parse_diagnostics`) then type-checks with a
  non-printing diagnostic collector.
- WebAssembly text (`.wat`): at parity with Wax. Formatting, diagnostics and
  document outline via `formatWat` / `checkWat` / `symbolsWat` exports (same wasm
  module; the WAT parser validates instead of type-checking), plus syntax
  highlighting (the TextMate grammar moved from the docs into the extension, now
  the single source both use), snippets, and language configuration.

## Tier 1: cheap wins (reuse existing toolchain output)

- [x] **Richer diagnostics.** `check` currently drops two things the toolchain
  already produces: the parser's `related` labels (e.g. "unclosed `(` started
  here") and the typer's `entry_hint`. Surface them as
  `Diagnostic.relatedInformation` and append the hint. Small change, real UX
  bump.
- [x] **Convert / preview commands.** The toolchain's reason for existing is
  wax <-> wat <-> wasm. Added `toWat` / `toWax` exports and the commands "Wax:
  Show compiled WAT" (from a `.wax` file) and "Wax: Show as Wax" (from a `.wat`
  file), each opening the conversion in a read-only virtual document
  (`wax-preview:` scheme) beside the source and re-rendering live as the source
  changes. Still open: a `toWasm` binary export plus "Convert to .wasm" writing a
  file (binary has no useful text preview, so it is a separate file-I/O feature).
- [x] **Warm the runtime on `activate()`** so the first format/check has no lag.
  Tiny.
- [ ] **Settings.** e.g. `wax.diagnostics.enable`, and expose the formatter width
  (currently hard-coded to 100). Small.

## Tier 2: moderate, high navigation value (walk the AST we already parse)

- [x] **Document outline / breadcrumbs** (`DocumentSymbolProvider`). We already have
  the module AST from `parse_diagnostics`; walk it to emit functions, globals,
  types, memories, and tags. Enables the outline view, breadcrumbs,
  Ctrl+Shift+O, and sticky scroll, with no new analysis. Cheapest big-feel win.
- [ ] **Quick fixes** (`CodeActionProvider`) for the mechanical lints, e.g.
  `x = x + e` -> `x += e` (compound assignment), redundant-operation removal,
  struct-field punning. Feasible wherever the rewrite is derivable from the lint.
- [x] **WAT support.** The toolchain already parses, validates, and formats `.wat`.
  Added a `wat` language contribution plus `formatWat` / `checkWat` / `symbolsWat`
  exports so the same in-process runtime gives WAT users formatting, diagnostics
  and a document outline too.
  Implemented as **option A** (one combined wasm module, both languages) after
  measuring the alternatives: the WAT lexer/parser/validator adds ~490 KB raw
  (730 KB -> 1220 KB; +87 KB gzipped), which was deemed acceptable given the load
  is already instant and option A avoids duplicating the TS providers and the
  build/publish story that two modules (option B) or two extensions (option C)
  would need.

## Tier 3: bigger language-server features

The "real language server" features. They do *not* form one tier gated on the
same thing: `Typing.f` already returns a fully-typed tree (its annotation is
`storagetype option array * location`, i.e. type **and** span at every node), so
some features only need to *index* that tree, while others need information it
does not carry. Three distinct prerequisites:

1. *Indexing only* — walk the tree `Typing.f` already returns. **Done** (hover,
   inlay hints).
2. *Name resolution* — the annotation carries types + spans but not def<->use
   links (which local/function/type a name binds to); the resolver would need to
   record them. The one prerequisite still outstanding.
3. *Error-tolerant parsing* — **done**: `parse_recover` (sync-token panic mode)
   yields a best-effort AST past syntax errors, and `check`/hover/outline/inlays
   all run on it, so features work mid-edit; `check` reports every syntax error,
   not just the first.

- [x] **Hover types.** *Indexing only.* Added a `hover` export
  (`wax_format_js.ml`) that parses with recovery, type-checks with `Typing.f_infer`
  (a variant of `Typing.f` that keeps the typed tree with its inference cells
  intact, rather than resolving them to storage types: every node's annotation is
  its result cells plus its span), then walks it with `Ast_utils.map_modulefield`
  for the innermost node whose span contains the cursor and renders the type with
  `Infer.output_inferred_type` — the same rendering diagnostics use, so a callee
  reads `fn(a: i32, b: i32) -> i32`, a flexible literal `number`/`int`, an
  unresolved cell `any` (rather than the resolved form's bare valtype and ugly
  synthetic `<…>` names). A single value shows as the bare type, several as a
  tuple. A statement (no value) and a fully unknown/error node (`is_unknown_or_error`)
  show no hover at all, so hovering blank or broken regions stays quiet. A name
  that is not an expression node (a type reference like `&point`, an assignment
  target, a bare global) falls back to what its resolved reference recorded — the
  type's definition or the variable's type; when both an expression node and a
  name reference cover the cursor the smaller span wins (so the type in `e as &t`
  beats the cast's result). A `HoverProvider` in `extension-common.ts` shows it
  in a `wax` code block. Wax only: WAT's validator builds no typed tree.
  Recovery (not a last-good-tree cache) keeps it alive through most mid-edit
  states; a buffer the recovering parser cannot salvage shows no hover. The
  parse + type-check is cached by source content and shared with the diagnostics
  pass (which now also runs `f_infer`, since it emits the same diagnostics and
  yields the tree for free), so a repeat hover on an unchanged buffer is a pure
  tree walk (~0.4 ms on a 2400-line file) rather than a re-analysis (~20-60 ms).
- [x] **Inlay hints** (show inferred `: i32` on `let`s). *Indexing only.* Added
  an `inlays` export that reads the same cached cell tree, walks it with the new
  `Ast_utils.iter_module_instr` (which exposes each node's `desc`, unlike
  `map_instr`), and for every un-annotated `let` binding emits `: <type>` at the
  name's end — the binding's type being the matching result of its initializer.
  A binding the user already annotated, the discard binding (`_ = e`), and one
  whose type is unknown/error are skipped. An `InlayHintsProvider` in
  `extension-common.ts` renders them (no padding, so `: i32` reads as written).
  Wax only.
- [x] **Name resolution.** *Was prereq 2.* The type checker now records, when
  given a `resolve_links` sink, each name/label *use* span paired with its
  *definition* span(s) — `Typing.reference`, `Typing.f_infer`. Module-field
  references (functions/globals/types/tags/memories/tables/data/elem) are caught
  at the single choke point `Tbl.resolve` (the `Namespace` already stored each
  definition's location); locals carry their binder span in `ctx.locals`, recorded
  at `resolve_variable`; labels carry the label ident in `control_types`, recorded
  at `branch_target`. Recording during type checking means the typer's own scope
  decides — shadowing and repeated same-name locals resolve to the right binder
  for free. Synthesized (dummy-location) and self references are dropped.
- [x] **Go to definition.** Built on the above: `definition` export walks the
  recorded references for the use under the cursor and returns its definition
  span(s) (several only across conditional branches); a `DefinitionProvider` in
  `extension-common.ts`. Wax only.
- [x] **Find references + document highlight.** The inverse of the `reference`
  links: the cursor picks a symbol (from a use it sits on, or a definition), and
  a `references` export gathers every reference sharing a target definition plus
  the definition(s). A `ReferenceProvider` (Find All References) and a
  `DocumentHighlightProvider` (highlight the symbol in the document) share it —
  both want the same set, since every occurrence is in this file. Wax only.
- [ ] **Rename.** The same inversion, but it *edits*, so it needs completeness:
  every occurrence must be recorded or rename silently corrupts code. Audit that
  the reference index catches all occurrences (and add the declaration where a
  definition is not itself a recorded use) before trusting it. Then a
  `RenameProvider` with a conflict/validity check.
- [ ] **Semantic tokens.** Distinguishing locals / params / functions / types
  could reuse the resolution now recorded (classify each use by its binder kind);
  a coarser version could come from parse-tree structure alone.
- [ ] **Completion** (locals, functions, types, intrinsics) beyond the current
  snippets. Both prerequisites — name resolution (in-scope binders) and error
  tolerance — are now in place; remaining work is the provider itself.
- [x] **Multi-error syntax recovery.** *Was* prereq 3, now delivered: `check`
  runs through `parse_recover` and reports every syntax error at once, not just
  the first.

## Ops

- [x] **CI**: build + `dune runtest` + `npm run test:web` on PRs / main
- [ ] a marketplace publish job.

## Suggested next step

Name resolution records use -> definition links during type checking; go-to-
definition, hover-on-names, and find-references / document-highlight all ship on
top. What is left is provider-level, not new analysis: **semantic tokens**
(classify each use by its binder kind — a small `kind` on the recorded reference,
then a token provider), **completion** (enumerate the in-scope binders), and
**rename** (find-references that edits, so gated on auditing the reference index
for completeness). Semantic tokens is the smallest next step and reuses the links
directly; rename is the highest-value but needs the completeness audit first.
