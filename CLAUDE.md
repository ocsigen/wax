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

Six libraries. The core data flow:

```
Wax source ──→ lib-wax (parse, type-check) ──→ lib-conversion ──→ lib-wasm ──→ WAT/WASM output
WAT/WASM   ──→ lib-wasm (parse, validate)  ──→ lib-conversion ──→ lib-wax  ──→ Wax output
```

- **lib-wax/** - Wax language: expression-oriented AST, Menhir parser, type checker
- **lib-wasm/** - WebAssembly: functor-based AST (`Instructions(X)`), binary and text format handling
- **lib-conversion/** - Bidirectional AST transformation between Wax and WAT
- **lib-utils/** - Shared infrastructure: diagnostics, source locations, formatting helpers
- **lib-driver/** - `wax-lib`, the public embedding API (`Wax`); the per-stage libraries above are internals
- **lib-editor/** - Editor analysis (`Wax_editor` / `Wat_editor`), shared by the LSP server (`lib-lsp/`) and the VS Code wasm wrapper (`src/editor/`)

All 9 conversion pipelines are supported (any combination of wax/wat/wasm as input/output).

## Cross-cutting invariants

- **Lints are mirrored.** A lint lives in both `lib-wax/typing.ml` (the Wax
  typer) and `lib-wasm/validation.ml` (the Wasm validator), so it fires on wax,
  wat and wasm input alike. `fuzz/oracle.sh`'s lint-parity oracle enforces this
  and documents the few intentionally one-sided ones. Adding a lint means
  adding it twice.
- **Decompiled widths are recorded.** Every node `from_wasm` emits must either
  record the type its source opcode states or be explicitly marked contextual;
  see `Ast.expectation` in `lib-wax/ast.ml`, which explains why an unrecorded
  node is the width machinery's one silent failure class.

## CLI Interface

`docs/src/cli.md` is the reference for the commands, flags, defaults, warning
names and exit codes; it is regenerated into `skills/wax/cli.md` and diffed
under `dune runtest`. Update it in the same commit as a CLI change instead of
restating it here. The commands are `convert` (the default), `format`, `check`
and `lsp`.

What the user docs don't say:

- cmdliner won't fall through to the default command on a leading positional,
  so `main.ml` rewrites `Sys.argv` (the js_of_ocaml trick) to keep the bare
  `wax <file>` form working — edit that heuristic when adding a subcommand.
- Exit status: `0` success, `123` a usage error, `124` a cmdliner parse error,
  `125` an internal error, `128` input rejected by a diagnostic (the
  distinction is misuse vs bad input). `fuzz/lib.sh`'s `classify_wax` mirrors
  the contract — keep them in sync.
- A text input is validated before it is converted to a *different* format, so
  the conversion and lowering passes may trust their input. A same-format
  conversion and a wasm binary input are not validated; `-v` forces it.
- `lsp` (`src/lib-lsp/`) is a thin protocol layer over `src/lib-editor/`, the
  analysis the VS Code wasm wrapper (`src/editor/`) shares. A language feature
  belongs in `lib-editor` as a `*_string` function; both front ends only
  marshal its result.

## Non-Negotiable Rules

1. **Test integrity:** NEVER modify `.expected` files to make tests pass. If a test fails, the code is broken. NEVER modify `dune` rules in `test/` without explicit permission.

2. **Menhir workflow:** The canonical grammars are `src/lib-wax/parser.mly` and `src/lib-wasm/parser.mly`. Only edit these source files — NEVER manually edit generated parser `.ml` files or the `dune.menhir` include. Parser error messages are generated too; the one hand-edit surface is the `parser_messages.overrides` sidecar beside each grammar (see Testing).

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
- `wasm-test-suite/` — the official WebAssembly spec suite (`core/`, `legacy/`), run together with `additional-tests/` (extra `.wast` inputs) by `run_wasm_testsuite.exe` against the top-level `wasm_test_suite.expected` and `wasm_test_suite.custom-descriptors.expected` goldens.
- `wasm-tools-suite/` — the vendored self-checking `.wast` corpus from wasm-tools' `tests/cli`, with its own `wasm_tools_suite{,.custom-descriptors}.expected` goldens and a `blacklist` for what wax cannot run.
- `wasmoo/` — round-trip/formatting corpora (`wasm-source/`, `wasm-formatted/`, `wasm-round-trip/`); its `dune.inc` is generated by `gen_dune.ml`, so don't hand-edit it.
- A family of OCaml tests, each an executable whose output is diffed against a committed `.expected`: `diagnostics/`, `editor-wax-features/`, `editor-wat-features/`, `editor-wat-recovery/`, `method-consistency/`, `name-resolution/`, `recovery/`, `recovery-wat/`, `unicode/`. `keyword-consistency/` and `subtype-lattice/` are self-checking instead, with no golden.

`dune promote` accepts changes to those goldens too.

The generated parser error messages are golden-tested as well. The generator is
`stele`, a vendored sub-project under `vendor/stele/` with its own
`dune-project` (see `vendor/stele/README.md`); `src/lib-wasm/dune.menhir` drives
it for both grammars. Two goldens guard it: `src/lib-{wax,wasm}/parser_messages.expected`,
the sentence→message projection, so a grammar or generator change lands as a
reviewable message diff; and `parser_messages.stats.expected`, the
message-quality summary, so a quality regression fails `dune runtest` even when
the message diff itself looks plausible. Review the diff, then `dune promote`.
Two wax-side gotchas: an entry in a grammar's `parser_messages.overrides` whose
sentence no longer keys an error state fails the build, and `src/lib-utils/dune`
deliberately `(copy …)`s stele's single runtime module into `wax_utils` instead
of linking the `stele.runtime` library, so no vendored library leaks into
`wax-lib`'s installed metadata — `vendor/stele/runtime/` stays the source of
truth.

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
- **CLI flags or defaults** → `docs/src/cli.md`.
- **Wax↔WASM mapping** → `docs/src/correspondence/*.md`.

A user-visible change also needs an entry under `## Unreleased` in
`CHANGES.md`, in the same commit, under the matching `###` heading
(Language, Command line, Warnings, Diagnostics, Editors, Fixes,
Performance, Library, Documentation). `dune-release` reads the top entry
when cutting an opam release, so an unlisted change ships unannounced.
Write it for a user: what changed and why it matters, not how it was
implemented. A change confined to the VS Code extension goes in its own
`editors/vscode/CHANGELOG.md` instead.

Every `wax` code block in `docs/src/examples.md` is compiled by `test/cram-tests/docs-examples.t`, so a stale example fails `dune runtest`. After editing examples, run `dune runtest` then `dune promote`. (Do not hand-edit the generated `docs/book/` HTML.)
