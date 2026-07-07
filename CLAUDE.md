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
bare `wax <file>` form working — edit that heuristic if adding subcommands.

**convert** (default) — `dune exec wax -- [options] [INPUT]`. `INPUT` is optional; reads from stdin if omitted.

| Flag | Long | Description |
|------|------|-------------|
| `-i` | `--input-format` | Input format: `wax`, `wat`, `wasm` (default: auto from extension, else `wax`) |
| `-f` | `--format` / `--output-format` | Output format: `wax`, `wat`, `wasm` (default: `wasm`) |
| `-o` | `--output` | Output file (default: stdout) |
| `-v` | `--validate` | Force validation everywhere and report unused locals. Text input (wax/wat) converted to a *different* format is validated by default already; this additionally validates a same-format conversion and a trusted wasm binary input |
| `-s` | `--strict-validate` | Stricter validation |
| `-D` | `--define` | Set a conditional-compilation variable (`NAME`, `NAME=true/false`, `NAME=N.N.N`, `NAME=STR`); specializes `#[if]`/`(@if)` annotations. Repeatable |
| `-X` | `--feature` | Enable/disable an optional proposal (off by default): `NAME[=on\|off]`. Known: `custom-descriptors` (exact refs, descriptor structs + instructions), `compact-import-section` (group same-module imports in the binary; gated on output, always accepted on input). Repeatable |
| `-W` | `--warn` | Set a warning's level: `NAME=LEVEL` where `NAME` is a warning (`unused-local`, `unused-field`, `unused-import`, `unused-label`, `shift-count-overflow`, `constant-trap`, `tautological-comparison`, `constant-condition`, `unused-result`, `dead-code`, `cast-always-fails`, `eager-select`, `precedence`, `redundant-operation`, `truncated-coverage`, `naming-conflict`, `reserved-word-rename`, `generated-name`), a group (`unused`, `correctness`, `redundant`, `naming`), or `all`, and `LEVEL` is `hidden`/`warning`/`error`. The `correctness` lints run during validation and are shown by default; the `redundant` group (just `redundant-operation`) and the `naming` warnings (Wasm→Wax renames/generated names) are hidden by default. Most lints are mirrored on both sides — the Wax typer (`lib-wax/typing.ml`) and the Wasm validator (`lib-wasm/validation.ml`) — so they fire on Wax, WAT and WASM input alike (exceptions: `precedence` is Wax-only, as WAT/WASM have no infix precedence; `eager-select`'s Wasm side covers only folded `select`); all are gated by `warn_unused` (tied to `-v`, always on under `check`). In the validator: the constant-operand/dead-code/redundant-arithmetic ones live in `lint_body` (which also hosts `eager-select`, walking folded `select` operands for a trapping/effectful subtree — unfolded `select`s are out of reach); `unused-label` via a usage flag on each control frame set in `branch_target`; `unused-field`/`unused-import` via marking resolved function/global indices used in `get_function`/`get_global` plus exports/start; `cast-always-fails`/redundant-cast in `lint_cast` (peeks the operand via `with_current_stack` at `RefCast`/`RefTest`). Later settings override earlier; repeatable. The `WAX_WARN` env var (comma/space-separated `NAME=LEVEL` specs) seeds defaults applied *before* `-W` — it layers under `-W` (unlike cmdliner's built-in env fallback), so `-W` refines it rather than replacing it. |
|      | `--fold` / `--unfold` | Force folded / unfolded instruction form (default: auto) |
|      | `--desugar` | Expand the Wax-specific `(@string …)`/`(@char …)` annotations into core wasm (`array.new_fixed`/`i32.const`) so the output is plain WebAssembly text. Wat output only (usage error `123` otherwise); fails (`128`) if an `(@if …)` remains unresolved — resolve with `-D` |
|      | `--color` | Color output: `auto`/`always`/`never` |
|      | `--source-map-file` | Emit a source map to the given file (wasm output only; rejected for wat/wax output) |
|      | `--debug` | Enable developer debug output for a category (repeatable, comma-separated). Categories: `timing` (log each pass's wall-clock time to stderr) |

Binary output to a terminal is blocked; use `-o` to write WASM to a file.

A text input (wax/wat) is validated before being converted to a *different*
format, so a malformed module is rejected instead of reaching the conversion /
lowering passes (which trust their input). A same-format conversion (wat→wat,
wax→wax) only re-prints and is not validated by default; a wasm binary input is
trusted and not validated. `--validate` forces validation in every case.

**format** — `dune exec wax -- format [options] FILE…`. Reformats each file in its own format (detected from the extension unless `-f` forces one). Formatting never validates.

| Flag | Long | Description |
|------|------|-------------|
| `-i` | `--inplace` | Write back to each file; otherwise exactly one file is formatted to stdout |
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
|      | `--color` / `--debug` | As for convert |

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

A few top-level `.expected` golden files also exist (e.g. `test/output.wat.expected`); `dune promote` accepts changes to those too. Per Rule 1, never hand-edit `.expected` output or `test/` `dune` rules to make a test pass.

## Documentation

User-facing docs live in the `docs/` mdbook (`docs/src/*.md`). When a change affects user-visible behavior, update the relevant page in the same commit:

- **Language syntax / type system** → `docs/src/language.md`, and add/adjust an example in `docs/src/examples.md`.
- **CLI flags or defaults** → `docs/src/cli.md` (and the CLI Interface table above).
- **Wax↔WASM mapping** → `docs/src/correspondence/*.md`.

Every `wax` code block in `docs/src/examples.md` is compiled by `test/cram-tests/docs-examples.t`, so a stale example fails `dune runtest`. After editing examples, run `dune runtest` then `dune promote`. (Do not hand-edit the generated `docs/book/` HTML.)
