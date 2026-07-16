# Contributing to Wax

Thanks for your interest in improving Wax. This document covers both the
mechanics of submitting a change and the engineering knowledge you need to make
one safely. For a high-level architecture overview, see the [README](README.md).

## Getting set up

```sh
opam install . --deps-only   # dependencies
dune build                   # build
dune runtest                 # full test suite
```

## Submitting a change

1. **Open an issue first** for anything non-trivial, so the approach can be
   discussed before you invest in it.
2. **Work on a branch** off `main`; keep each PR focused on one concern.
3. **Before you push, the change must pass the gate:**
   ```sh
   dune build @fmt    # code is formatted (fixes are shown as a diff)
   dune runtest       # the whole suite is green
   ```
   Accept intended output changes with `dune promote`; **never** hand-edit
   `.expected` files or `test/` `dune` rules to make a test pass.
4. **Add tests** for new behaviour, including the interesting negative cases
   (see the testing notes below).
5. **Update the docs in the same commit** as the behaviour they describe (see
   [Docs move with behaviour](#docs-move-with-behaviour-same-commit)).
6. **Keep commits and diffs minimal**: change only what the change needs; don't
   reformat or refactor unrelated code in the same commit.

Commit messages follow the existing history: a short `area: summary` subject
(e.g. `typing: …`, `ci: …`, `fuzz: …`), imperative mood.

The rest of this document is the engineering side: how the compiler is
structured and what must move together when you touch it: the *cross-cutting*
changes, where touching one thing means updating several others.

## The data flow (know which way you're going)

There are two directions, and both matter for almost every change:

```
Wax source ─ lib-wax (parse → type) ─→ typed AST ─ lib-conversion/to_wasm ─→ lib-wasm ─→ WAT/WASM
WAT/WASM ─ lib-wasm (parse) ─→ lib-conversion/from_wasm ─→ Wax AST ─ lib-wax (type) ─→ lib-wax/output ─→ Wax
```

- **`lib-wax/`**: the Wax AST (`ast.ml`/`ast.mli`), Menhir parser
  (`parser.mly`), lexer (`lexer.ml`), type checker (`typing.ml`), and the Wax
  printer (`output.ml`).
- **`lib-conversion/`**: `to_wasm.ml` (Wax → Wasm, *trusts* its input),
  `from_wasm.ml` (Wasm → Wax), and the `recover_*` / `sink_let` passes that
  reconstruct higher-level Wax structure from decompiled Wasm.
- **`lib-wasm/`**: the Wasm AST, binary and text formats, validation.

### Which AST gets printed in which pipeline

The **typed** AST (what `Typing.f` returns) is used for *both* lowering *and*
printing, depending on the pipeline (see `src/bin/main.ml`):

| Pipeline | What is printed / lowered |
|----------|---------------------------|
| `wax → wax` (`format`) | the **parsed** AST (typing only validates) |
| `wax → wat` / `wax → wasm` | the **typed** AST, fed to `to_wasm` |
| `wat → wax` / `wasm → wax` | the **typed** AST, `Typing.f ~simplify:true \|> erase_types`, then printed |

The trap: because the typed AST is also what `wat→wax`/`wasm→wax` print, a
"desugaring" rewrite in `typing.ml` silently changes decompiler output too. A
surface construct that must round-trip has to be preserved through typing and
lowered by `to_wasm`, not desugared in the type checker (see the AST checklist
below).

## Checklist: changing the Wax AST

Adding, removing, or changing the arity of a constructor in
`src/lib-wax/ast.ml`. A full `dune build` flags every non-exhaustive match to
fix — including the Wax printer (`lib-wax/output.ml`), where **round-trip
depends on getting the case right**, not merely compiling. The decisions the
compiler can't make for you:

1. **Decide the round-trip story** using the table above. If the construct has a
   surface syntax that should survive `wasm → wax`, keep it in the typed AST and
   lower it in `to_wasm`; do **not** desugar it in `typing.ml`.
2. **Reconstruct it in `from_wasm.ml`** if the reverse direction should produce
   it (e.g. recognising `x = x + e` and emitting `x += e`).
3. **Update the fuzzers so they actually exercise it** (see below).

## Checklist: adding Wax surface syntax

On top of the AST checklist:

- **Lexer** (`lib-wax/lexer.ml`): new tokens. Sedlex is longest-match, so a
  longer token (`+=`) wins over its prefix (`+`) regardless of rule order.
- **Parser** (`lib-wax/parser.mly`): token declarations (with their string
  aliases) and grammar rules. The canonical grammars are
  `src/lib-wax/parser.mly` and `src/lib-wasm/parser.mly`, with Wasm parser
  error messages in `src/lib-wasm/spec.mlyl`: only edit those sources, never the
  generated `.ml` or the `dune.menhir` include. Don't add precedence
  declarations you don't need: Menhir warns "the precedence level assigned to X
  is never useful", which means remove it.
- **Printer** (`lib-wax/output.ml`): so it round-trips and
  `dune build @fmt`-style idempotence holds.
- **Editor grammar** (`editors/vscode/syntaxes/wax.tmLanguage.json`): add new
  operators/keywords. TextMate/Oniguruma alternation is **leftmost-first, not
  longest**, so a multi-char operator must be listed *before* any single-char
  operator that is its prefix (put `+=`, `<<=`, … ahead of `=`, `<`, `<=`).
- **Docs**: see below.

## Fuzzers must be *exercised*, not just compiled

Making the fuzzers compile after an AST change is not the same as fuzzing the
new thing. `src/bin/fuzz_gen.ml` generates type-directed Wax;
`src/bin/fuzz_mutate.ml` mutates a Wax AST. If you add a construct, add a case
that **produces** it:

- `fuzz_gen.ml` output is round-tripped by `fuzz/oracle.sh`
  (`wax → wasm → wax → wasm`), so generating the surface form there exercises
  typing, `to_wasm` lowering, *and* `from_wasm` reconstruction in one shot.
- Keep generated modules well-typed (reuse the existing type-directed helpers
  and operator pools) so rejections stay meaningful; `fuzz_mutate.ml` may
  legitimately produce ill-typed mutants: those are *expected rejections*, not
  crashes.

The oracles live in `fuzz/` (see `fuzz/oracle.sh`, `fuzz/lib.sh`,
`fuzz/PLAN.md`); `fuzz/lib.sh`'s `classify_wax` mirrors the CLI exit-status
contract; keep them in sync if you change exit codes.

## Docs move with behaviour (same commit)

When a change affects user-visible behaviour, update the docs in the same
commit:

- Language syntax / types → `docs/src/language.md`, plus an example in
  `docs/src/examples.md` (**every `wax` block there is compiled** by
  `test/cram-tests/docs-examples.t`; bump its expected count when you add one).
- CLI flags / defaults → `docs/src/cli.md`.
- Wax↔Wasm mapping → `docs/src/correspondence/*.md` (document *both* directions:
  what a construct lowers to, and whether the reverse reconstructs it).

## Testing notes

The gate (`dune build @fmt` + `dune runtest`, accepting intended changes with
`dune promote`) is described under
[Submitting a change](#submitting-a-change). A few things specific to writing
and reviewing tests:

- Most tests are **cram tests** under `test/cram-tests/<name>.t/`; add a focused
  one for new behaviour, and cover the interesting negative cases (rejected
  inputs, forms that should *not* be reconstructed). The full suite also runs
  the WebAssembly spec suite and round-trip corpora (`test/wasmoo/**`).
- **Read a large `promote` diff before accepting it.** A feature can
  legitimately rewrite many round-trip corpus files, but every changed line
  should be explainable by your change: a surprise line is a bug, not a golden
  update.

## Releasing

Cutting a release of the toolchain, the VS Code extension, or the tree-sitter
grammar is documented separately in [`RELEASING.md`](RELEASING.md). The three
are versioned and released independently.
