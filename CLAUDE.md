# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Wax is a compiler toolchain providing a Rust-like syntax for WebAssembly. It supports bidirectional conversion between three formats: Wax (source), WAT (WebAssembly Text), and WASM (binary).

## Build Commands

| Action | Command |
|--------|---------|
| Build | `dune build` |
| Format | `dune build @fmt` (run before committing) |
| Test | `dune runtest` |
| Accept test output | `dune promote` |
| Run CLI | `dune exec wax -- <args>` |
| Install deps | `opam install . --deps-only` |

## Architecture

Four libraries with clear data flow:

```
Wax source ──→ lib-wax (parse, type-check) ──→ lib-conversion ──→ lib-wasm ──→ WAT/WASM output
WAT/WASM   ──→ lib-wasm (parse, validate)  ──→ lib-conversion ──→ lib-wax  ──→ Wax output
```

- **lib-wax/** - Wax language: expression-oriented AST, Menhir parser, type checker
- **lib-wasm/** - WebAssembly: functor-based AST (`Instructions(X)`), binary and text format handling
- **lib-conversion/** - Bidirectional AST transformation between Wax and WAT
- **lib-utils/** - Shared infrastructure: diagnostics, source locations, formatting helpers

All 9 conversion pipelines are supported (any combination of wax/wat/wasm as input/output).

## CLI Interface

`wax` is a `Cmd.group` with `convert` as the default command and `format` /
`check` subcommands. cmdliner won't fall through to the default on a leading
positional, so `main.ml` rewrites `Sys.argv` (the js_of_ocaml trick) to keep the
bare `wax <file>` form working — edit that heuristic if adding subcommands. The
group carries `--version` (from `dune-build-info`: the git tag at release build
time, else `dev`) and cmdliner's built-in `--help`.

**convert** (default) — `dune exec wax -- [options] [INPUT]`. `INPUT` is optional; reads from stdin if omitted.

| Flag | Long | Description |
|------|------|-------------|
| `-i` | `--input-format` | Input format: `wax`, `wat`, `wasm` (default: auto from extension, else `wax`) |
| `-f` | `--format` / `--output-format` | Output format: `wax`, `wat`, `wasm` (default: `wax`) |
| `-o` | `--output` | Output file (default: stdout) |
| `-v` | `--validate` | Force validation everywhere and report unused locals. Text input (wax/wat) converted to a *different* format is validated by default already; this additionally validates a same-format conversion and a trusted wasm binary input |
| `-s` | `--strict-validate` | Stricter validation |
| `-D` | `--define` | Set a conditional-compilation variable (`NAME`, `NAME=true/false`, `NAME=N.N.N`, `NAME=STR`); specializes `#[if]`/`(@if)` annotations. Repeatable |
| `-X` | `--feature` | Enable/disable an optional proposal (off by default): `NAME[=on\|off]`. Known: `custom-descriptors` (exact refs, descriptor structs + instructions), `compact-import-section` (group same-module imports in the binary; from text input, lowers a `import "m" {}` block / `(import "m" (item …))` group to a compact entry — shared-type Group2 when items match, else Group1, singleton block flattens, separate imports never merged; from binary input, coalesces same-module runs; explicit groups always preserved and always accepted on input). A module can also declare a feature itself with a `#![feature = "NAME"]` inner attribute (WAT: `(@feature "NAME")` module annotation) — declared ∪ enabled, resolved in `Typing.apply_declared_features`/`Validation.apply_declared_features`; an explicit `NAME=off` against a declaring module is a conflict error at the attribute. A binary persists declarations as `+name` entries of the `target_features` custom section (third-party entries preserved verbatim, never interpreted); decompiling restores attributes from those entries ∪ the gated encodings the decoder saw (`Feature.mark_used` in `wasm_parser.ml`), so output recompiles standalone. Repeatable |
| `-W` | `--warn` | Set a warning's level: `NAME=LEVEL` where `NAME` is a warning (`unused-local`, `unused-field`, `unused-import`, `unused-label`, `shift-count-overflow`, `constant-trap`, `tautological-comparison`, `constant-condition`, `unused-result`, `dead-code`, `cast-always-fails`, `eager-select`, `precedence`, `redundant-operation`, `truncated-coverage`, `naming-conflict`, `reserved-word-rename`, `generated-name`, `compound-assignment`, `field-punning`, `redundant-annotation`, `confusable-unicode`), a group (`unused`, `correctness`, `redundant`, `naming`, `suggestion`), or `all`, and `LEVEL` is `hidden`/`warning`/`error`. `confusable-unicode` (group `correctness`) reports a "Trojan Source" bidirectional control character (U+202A/B/D/E, U+2066–2069, U+206C) in a string a module carries — an export/import name, a string literal, a data segment, or a conditional string — that can make the source read differently than it runs; the scan (`Wax_utils.Unicode.first_confusable`) runs on both sides via `lint_confusable` (`typing.ml` / `validation.ml`), matching what `wasm-tools` rejects in string literals. The `correctness` lints run during validation and are shown by default; the `redundant` group (just `redundant-operation`), the `naming` warnings (Wasm→Wax renames/generated names), and the `suggestion` group are hidden by default. The `suggestion` group is emitted at severity `Suggestion` (not `Warning`) and each entry carries a machine-applicable `edit` (a source-slice-built replacement) — the Wax typer's mirror of what the `simplify` pass rewrites on the Wasm→Wax path, offered to hand-written Wax as editor quick fixes (`src/editor` → the VS Code `CodeActionProvider`) and shown by `wax check` only when enabled with `-W`: `compound-assignment` (`x = x + e` → `x += e`, requires `x` to be the binop's *first* operand), `field-punning` (`{x: x}` → `{x}`), `redundant-annotation` (a redundant type the inferred type already pins: a `let` annotation `let x: t = e` → `let x = e` — incl. the anonymous `_: t = e` and each binding of a tuple `let (a: t, b) = e`; a module-level global/`const` annotation `let counter: i32 = 0` → `let counter = 0`; a construction type name `{T| …}` → `{…}`; a block result type `do t { … }` → `do { … }`; and an `if` result type `if c => t { … }` → `if c { … }`); a redundant *cast* removal rides on the existing `redundant-operation` warning's `edit` instead. Some non-`suggestion` lints carry an `edit` too, so they surface as quick fixes as well: `unused-local` inserts `_` at the name start, Wax-side `unused-label` deletes the whole `'name:` prefix (the Wasm-validator side stays edit-less), and `precedence` wraps the tighter-binding sub-expression in parentheses (a single contiguous replacement, `(` ^ the source slice ^ `)`). All suggestion detection lives in `typing.ml`'s `suggest_*`/`lint_ref_cast` helpers (block/`if` result via `context_block_typ`/`suggest_if_result`, the shared deletion `edit` via `deletion_edit`), gated by `ctx.suggest` (mutually exclusive with `ctx.simplify` — enforced by an `invalid_arg` in `type_configuration`; `Typing.f`/`check` take `?suggest`). The `edit` is serialized by `--error-format json` (an `edit` object: the span fields plus `newText`). Most lints are mirrored on both sides — the Wax typer (`lib-wax/typing.ml`) and the Wasm validator (`lib-wasm/validation.ml`) — so they fire on Wax, WAT and WASM input alike (exceptions: `precedence` is Wax-only, as WAT/WASM have no infix precedence; `eager-select`'s Wasm side covers only folded `select`; the `suggestion` group is Wax-only); all are gated by `warn_unused` (tied to `-v`, always on under `check`). In the validator: the constant-operand/dead-code/redundant-arithmetic ones live in `lint_body` (which also hosts `eager-select`, walking folded `select` operands for a trapping/effectful subtree — unfolded `select`s are out of reach); `unused-label` via a usage flag on each control frame set in `branch_target`; `unused-field`/`unused-import` via marking resolved function/global indices used in `get_function`/`get_global` plus exports/start; `cast-always-fails`/redundant-cast in `lint_cast` (peeks the operand via `with_current_stack` at `RefCast`/`RefTest`). Later settings override earlier; repeatable. The `WAX_WARN` env var (comma/space-separated `NAME=LEVEL` specs) seeds defaults applied *before* `-W` — it layers under `-W` (unlike cmdliner's built-in env fallback), so `-W` refines it rather than replacing it. |
|      | `--fold` / `--unfold` | Force folded / unfolded instruction form (default: auto) |
|      | `--desugar` | Expand the Wax-specific `(@string …)`/`(@char …)` annotations into core wasm (`array.new_fixed`/`i32.const`), strip `(@feature …)` (pure metadata; resolution already ran), and synthesize the declarative elem segment (`(elem declare func …)`) the lenient reader lets you omit for a body-only `ref.func` (via `Wax_wasm.Desugar` → `Wax_wasm.Declare_refs`, mirroring `Validation`'s `refs` set; no-op when already declared, e.g. wax→wat / binary→wat) so the output is plain WebAssembly text that passes strict/spec validation with no annotation left. Wat output only (usage error `123` otherwise); fails (`128`) if an `(@if …)` remains unresolved — resolve with `-D` |
|      | `--color` | Color output: `auto`/`always`/`never` |
|      | `--error-format` | Diagnostic rendering: `human` (default), `json`, or `short`. `json` emits one JSON object per diagnostic per line (JSON Lines) to stderr — errors, warnings, and syntax errors alike — for editors/CI/AI; `short` emits one `file:line:col: severity: message` line (gcc/rustc style, 1-based column, `-W` name appended as `[name]`). `human` (the default) appends the same `-W` name to the diagnostic header as `[name]` (e.g. `Warning [unused-local]:`, via `output_error_no_loc`). Set process-wide via `Diagnostic.set_format` (like `set_policy`); the emitters `output_error_json`/`output_error_short` live in `lib-utils/diagnostic.ml` (json via yojson). Syntax errors carry the same structured payload as other diagnostics (`Parsing.syntax_error` = `{location; message; related; hint; fix}`, built by the smart constructor `Parsing.syntax_error`/the legacy-shape `syntax_error_pair` used across the lexers and grammars, exception payload now that record), so they emit `hint`/`related`/`edit` too; a `fix` (reusing `Diagnostic.edit`) is derived mechanically when `parse_recover` repairs the parse by inserting a token (missing `;`/operand — `Recover.insert`'s 4th tuple field is the inserted token's source text), shown in `human` as a `Help:` line for an unnamed Error only (`print_fix`, so promoted warnings keep their own message) and in `json` as an `edit`. Also on `check`/`format` |
|      | `--source-map` | Emit a source map alongside the output file and insert a `sourceMappingURL` custom section (wasm output to a file only; rejected for wat/wax output or stdout) |
|      | `--debug` | Enable developer debug output for a category (repeatable, comma-separated). Categories: `timing` (log each pass's wall-clock time to stderr) |

Binary output to a terminal is blocked; use `-o` to write WASM to a file.

A text input (wax/wat) is validated before being converted to a *different*
format, so a malformed module is rejected instead of reaching the conversion /
lowering passes (which trust their input). A same-format conversion (wat→wat,
wax→wax) only re-prints and is not validated by default; a wasm binary input is
trusted and not validated. `--validate` forces validation in every case.

**format** — `dune exec wax -- format [options] FILE…`. Reformats each file in its own format (detected from the extension unless `-f` forces one). Formatting never validates. With no `FILE`, reads stdin and writes the formatted result to stdout (requires `-f`, since there is no extension to detect; `-i`/`-c` are rejected) — the interface an editor formatter or shell pipe uses.

| Flag | Long | Description |
|------|------|-------------|
| `-i` | `--inplace` | Write back to each file; otherwise exactly one file is formatted to stdout (or none: stdin→stdout) |
| `-c` | `--check` | Write nothing; list unformatted files, exit non-zero if any (mutually exclusive with `--inplace`) |
| `-f` | `--format` / `--input-format` | Force the format of all files (overrides extension detection) |
| `-W` | `--warn` | Set a warning's level (as for convert) |
|      | `--color` / `--fold` / `--unfold` / `--debug` | As for convert |

**check** — `dune exec wax -- check [options] FILE…`. Validates each file (type-check Wax / well-formedness Wasm), no output, exits non-zero on failure.

| Flag | Long | Description |
|------|------|-------------|
| `-f` | `--format` / `--input-format` | Force the format of all files (overrides extension detection) |
| `-s` | `--strict-validate` | Strict reference validation (Wasm Text) |
| `-D` | `--define` | Set a conditional-compilation variable (as for convert); specializes `#[if]`/`(@if)` before validating. A partial set leaves the rest for the path-sensitive check. Repeatable |
| `-W` | `--warn` | Set a warning's level (as for convert) |
|      | `--all-errors` | Report every syntax error via panic-mode recovery instead of stopping at the first (text input only, Wax and Wat; ignored for a Wasm binary). Routes Wax through `Wax_conversion.Driver.wax_parse_recover` (then `Typing.check`) and Wat through `wat_parse_recover` (then `Validation.f`), each with `Diagnostic.set_recovery` on so real type/validation errors in intact regions surface while the recovery cascades are suppressed — for Wax the `unbound_name` cascade; for Wat (in `lib-wasm/validation.ml`) all warnings plus the stack-shape errors (`empty_stack`/`non_empty_stack`/`leftover_values`) an auto-closed/dropped body triggers |
|      | `--color` / `--debug` | As for convert |

**lsp** — `dune exec wax -- lsp`. Runs a Language Server Protocol server over
stdin/stdout (JSON-RPC), for editors other than VS Code (Neovim, Emacs, Helix,
…). It is a thin protocol layer (`src/lib-lsp/wax_lsp.ml`, on the `lsp` +
`jsonrpc` opam packages) over the `src/lib-editor/` analysis, the pure analysis
extracted from the VS Code wasm wrapper `src/editor/wax_format_js.ml` so both
consumers share it. That library is three modules: `Editor_common` (the value
types the features return and the shared helpers — trivia, positions, diag
rendering), `Wax_editor` (the Wax features), and `Wat_editor` (the Wasm-text
features, `open Editor_common`); the library is `(wrapped false)` so all three
are top-level. Every language feature is a `*_string` function
(`Wax_editor.hover_string` / `Wat_editor.hover_string`, dispatched on the
document's language); the LSP server and the JS wrapper only marshal their
results. The loop
is synchronous (one request at a time), document sync is `Full` (each change
carries the whole buffer, which is what `Wax_editor`'s source-keyed analysis
cache expects), and the position encoding is negotiated at `initialize` (UTF-8
when the client offers it, else UTF-16; the `*_string` functions take
a `?encoding` that defaults to UTF-16, so the JS wrapper is unaffected, and
`Editor_common.position ~encoding` maps results back). Requests
map 1:1 to the editor functions (hover, definition, type-definition,
references, document-highlight, prepare-rename/rename, document-symbol,
completion, signature-help, inlay-hint, folding, selection-range,
semantic-tokens, formatting); `code-action` reuses the diagnostics pass, turning
each `diag` that carries a machine-applicable `edit` (a `Suggestion`, or a
fixable warning like a redundant cast) whose span meets the request range into a
`quickfix` `WorkspaceEdit` — the native mirror of the VS Code
`CodeActionProvider`. Diagnostics are pushed via `publishDiagnostics` on
open/change (lint diagnostics carry the `-W` code, a `codeDescription` link to
the docs, and `DiagnosticTag.Unnecessary` via `Warning.is_unnecessary`; a
`Suggestion` maps to `DiagnosticSeverity.Hint`). The one
setting is `wax.define` (conditional-compilation defines, mirroring `-D`), read
from `initializationOptions` and `workspace/didChangeConfiguration` and threaded
into `check_string_with_defines`/`completion_string`. A Wasm-text document is
served by `Wat_editor` (`is_wat` dispatches on the language the client declared
at `didOpen` via `languageId` — `wat` vs `wax` — recorded per-URI in
`doc_is_wat`, falling back to the `.wat` extension only for an unrecognized id;
so an editor serving WAT under another extension or an unsaved buffer is
honoured): formatting, diagnostics,
outline, folding, selection-range; hover, signature-help and semantic-tokens
(from `Validation.f`'s `?record_types` sink — each value at its instruction span,
identifiers at their own span: a call's callee signature, a local/global's type,
a type reference's source subtype; the subtype is kept in the reference-keyed
`index_mapping` so deduplicated types still show their own definition); and
navigation/rename (go-to-definition, references, document-highlight,
prepare-rename, rename — over `Wax_wasm.Resolve`, the WAT name-resolution pass,
which also classifies the semantic tokens; rename detects clashes like the Wax
side by re-resolving the rewritten buffer and rejecting a change to the renamed
binding's occurrence count, and both sides return the shared
`Editor_common.rename_outcome`); and type-definition (from a value of
a named reference type to that type's definition, via a def-span recorded in the
sink at each such value); and completion (WAT operands are indices into flat
spaces and the enclosing instruction fixes which space, so `Resolve.f`'s
`?expected` sink records at every index use-site — including the zero-width `0`
the recovering parse inserts for a missing operand — a thunk of the in-scope
names of that space; completion finds the use-site at the cursor and offers those
names with their leading `$`, letting the client filter by the typed prefix);
and inlay-hint (WAT is explicitly typed, so what is implicit is the name behind a
numeric index, not a type: after each numeric index that resolves to a named
definition, `Wat_editor.inlays_string` shows that name — from `Resolve`'s uses —
so `(local.get 0)` reads as `(local.get 0 $x)`; a symbolic use or an anonymous
target shows nothing). `--stdio` is
accepted and ignored. The
`wax` binary builds in both `exe` and `wasm` modes, and `lsp`/`jsonrpc` compile
under wasm_of_ocaml, so the npm wasm CLI still builds with the subcommand linked
in.

| Flag | Long | Description |
|------|------|-------------|
|      | `--stdio` | Accepted and ignored (stdin/stdout is the only transport); present so editors that pass it by convention do not error |

**Exit status** (shared by all commands; see `docs/src/cli.md`): `0` success;
`123` a usage error (bad flag combination) or a `format --check` run that found
files needing formatting; `124` a command-line parse error (cmdliner); `125` an
internal error; `128` the input was rejected by a diagnostic — a parse,
validation, or type error, or a malformed wasm binary (also a `check` that
found any problem). The distinction is misuse (`123`) vs bad input (`128`).
Rejected input exits `128` wherever detected: `parsing.ml` (syntax),
`Diagnostic.output_errors` (validation/type), and the `check` aggregate;
`usage_error` in `main.ml` owns `123`. `fuzz/lib.sh`'s `classify_wax` mirrors
the contract — keep them in sync.

## Non-Negotiable Rules

1. **Test integrity:** NEVER modify `.expected` files to make tests pass. If a test fails, the code is broken. NEVER modify `dune` rules in `test/` without explicit permission.

2. **Menhir workflow:** The canonical grammars are `src/lib-wax/parser.mly` and `src/lib-wasm/parser.mly`; parser error messages live in `src/lib-wasm/spec.mlyl`. Only edit these source files — NEVER manually edit generated parser `.ml` files or the `dune.menhir` include. Stray root-level copies like `parser_no_param.mly` are scratch, not source.

3. **Minimal diffs:** Only change the code you intended to change. Do not clean up unrelated code in the same commit.

4. **Keep related functions together:** When adding a function, insert it near related functions.

## OCaml Conventions

- Pure functional style: use recursion and higher-order functions, not imperative loops
- Pattern matching for control flow on ADTs; ensure exhaustiveness
- `snake_case` for values/functions, `PascalCase` for modules and constructors
- Top-level functions must have signatures in `.mli` files
- `.mli` files are the primary API documentation

## Key Files by Task

- **Adding Wax syntax:** `src/lib-wax/parser.mly`, `src/lib-wax/typing.ml`
- **Fixing WAT/WASM bugs:** `src/lib-wasm/validation.ml`, `src/lib-wasm/ast.ml`
- **Improving errors:** `src/lib-utils/diagnostic.ml`, `src/lib-wax/typing.ml`
- **CLI changes:** `src/bin/main.ml`
- **Conversion logic:** `src/lib-conversion/to_wasm.ml`, `src/lib-conversion/from_wasm.ml`

## Testing

Run everything with `dune runtest`; accept new output with `dune promote`.

Most tests are **cram tests** under `test/cram-tests/*.t/` (enabled by the `(cram ...)` stanza in `test/cram-tests/dune`). Each `.t` directory holds a `run.t` script with `  $ wax ...` commands and the expected output embedded inline below them, plus any input fixtures. To add or update one, edit/create the `.t` directory, run `dune runtest`, then `dune promote`.

Other suites under `test/`:
- `wasm-test-suite/` — the official WebAssembly spec suite (`core/`, `legacy/`).
- `wasmoo/` — round-trip/formatting corpora (`wasm-source/`, `wasm-formatted/`, `wasm-round-trip/`); its `dune.inc` is generated by `gen_dune.ml`, so don't hand-edit it.
- `diagnostics/` — an OCaml test (`test_diagnostic.ml`) checked against `test_diagnostic.expected`.
- `additional-tests/` — extra `.wast` inputs.
- `link-coherence/` — `check_coherence.ml` cross-checks that the linker's three independent encodings of the binary format (`Wasm_parser` decode, `Wasm_output` encode, `Wasm_link.Scan` byte-rewrite) agree, over a corpus of real modules built from `wasmoo/wasm-source/` with the `wax` CLI. Golden output (`link_coherence.expected`) is empty.

A few top-level `.expected` golden files also exist (e.g. `test/output.wat.expected`); `dune promote` accepts changes to those too. Per Rule 1, never hand-edit `.expected` output or `test/` `dune` rules to make a test pass.

The tree-sitter grammar (`tree-sitter-wax/`) is a separate node subproject with
its own CI (`.github/workflows/tree-sitter.yml`), **not run by `dune runtest`**.
Its corpus smoke test parses every `.wax` fixture under `test/cram-tests/` (plus
doc examples) and asserts zero ERROR/MISSING nodes, so a newly added
*syntactically* invalid fixture (a negative parse test) must also be registered
in `tree-sitter-wax/test/expected-errors.txt` — otherwise the tree-sitter job
goes red even though `dune runtest` is green (wax's parser enforces some
semantic constraints, e.g. pow2 page sizes or escape ranges, that the pure
grammar does not, so the two disagree on which fixtures parse). Check locally
before pushing fixture or grammar changes with `npm run smoke` in
`tree-sitter-wax/`.

## Documentation

User-facing docs live in the `docs/` mdbook (`docs/src/*.md`). When a change affects user-visible behavior, update the relevant page in the same commit:

- **Language syntax / type system** → `docs/src/language.md`, and add/adjust an example in `docs/src/examples.md`.
- **CLI flags or defaults** → `docs/src/cli.md` (and the CLI Interface table above).
- **Wax↔WASM mapping** → `docs/src/correspondence/*.md`.

Every `wax` code block in `docs/src/examples.md` is compiled by `test/cram-tests/docs-examples.t`, so a stale example fails `dune runtest`. After editing examples, run `dune runtest` then `dune promote`. (Do not hand-edit the generated `docs/book/` HTML.)
