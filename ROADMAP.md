# Roadmap

## Current State

The core toolchain works: all 9 conversion pipelines (wax/wat/wasm in any combination) are wired up, the CLI is functional, and there's solid test infrastructure including the official WebAssembly spec test suite. The diagnostic system is well-designed with source snippets and spell-check hints.

Linear memory, tables, data and element segments, SIMD/v128 (including relaxed SIMD), threads/atomics, stack switching, wide arithmetic, branch hints, custom page sizes, and conditional compilation (`#[if]`/`(@if)`) now round-trip through Wax with dedicated syntax; multi-value results are handled natively (the binaryen tuple extension was removed), and a module can be named with `#![module = "name"]`.

CI (`.github/workflows/`) builds and tests on an OS/OCaml matrix and deploys the docs; a differential/round-trip fuzzing harness (`fuzz/`) guards the conversions; and the CLI can be packaged for npm as a single cross-platform `wasm_of_ocaml` artifact (§6).

Implicit function types (inline signatures with no `(type N)` reference, appended to the end of the type index space per the text format) are now collected up front during validation and binary conversion, so `(type N)` references to them resolve and inline `call_indirect` signatures no longer break subtyping. The `func` element-segment shorthand is also printed correctly: it denotes the non-nullable `(ref func)` element type, so a nullable `funcref` segment is printed explicitly rather than lossily abbreviated.

## 1. Critical Bugs

- **Dropped-expression width drift (fixed, 2026-07-03): the round trip
  could introduce a trap.** `wasm → wax → wasm` retyped a *dropped*
  all-literal integer expression from i64 to i32 — a drop supplies no
  expected type, bare literals stay flexible, and the tree re-defaults
  (`2147483648` fits u32, so `Int` → i32). Repro: `(drop (i64.div_u
  (i64.const 1) (i64.add (i64.const 2147483648) (i64.const 2147483648))))`
  decompiled to `_ = 1 /u (2147483648 + 2147483648);` and recompiled as
  `i32.div_u` with divisor 0 — a trap the original didn't have. Both
  modules validate, so only execution oracles see the class. **Fix**
  (`from_wasm.ml`): the width is unrecoverable after conversion (the
  i32/i64 forms yield identical Wax ASTs), so `Stack` entries now carry the
  numeric width the opcode states (consts + arithmetic bin-ops; `None`
  elsewhere, which is safe — such trees carry a typed anchor that re-pins
  them), and `Drop` wraps a non-i32-width operand in an identity cast. Part
  (2) needed no new code: `simplify`'s `load_bearing_literal` (`typing.ml`)
  already keeps such a cast only when the operand tree re-defaults to a
  different width and drops it otherwise. One refinement over the original
  design: the cast fires for `` `I64``/`` `F32`` **and `` `F64``** — a wasm
  `f64.const 1` prints as the bare integer `1`, so a dropped integer-valued
  `f64` add/sub/mul also re-defaults to i32; only i32 (the universal
  default) never needs a pin. Identity lowering keeps the re-emitted binary
  byte-identical; dead code is exempt (never executes). Cram test
  (`test/cram-tests/drop-width-drift.t`): the round-tripped wat must still
  say `i64.div_u`. Multi-binding lets were checked too and need no change —
  every multi-value producer (call signature, kept block/if annotation,
  wide-arith intrinsic) pins the literals inside it, so a tuple `_` slot
  drops an already-concrete value. Oracle coverage landed (`fuzz/PLAN.md`
  §9): `fuzz/drop-width.sh` guards the shape and `MODE=wax` exec oracles
  confirmed to flag the behavioural divergence.
  **Planned refactor**: re-encode drop as an anonymous `Let` slot —
  `Let ([(None, Some I64)], Some e)` — instead of `Set (None, None, e)` +
  identity cast. The annotation is the principled home for the width (the
  cast form overloads `as` — pin vs genuine conversion — on the reader),
  the keep/drop decision reuses `bind_let_value`/`annotation_needed`
  verbatim instead of the cast-specific `load_bearing_literal` path, and
  `Set` gains a mandatory target (`ident * binop option * instr`), making
  `_ += e` unrepresentable. Surface: `_ = e;` unannotated, `_: i64 = e;`
  annotated (no `let` — nothing is bound; lookahead after `_` is clean).
  Byte-fidelity preserved by construction (annotated slot lowers to value
  + `drop`); `drop-width.sh` + the cram test are the regression net.

- **Width-eraser drift, the general class (fixed, 2026-07-03): the drop
  bug had siblings, including a live-value miscompilation.** The root
  cause generalized: any consumer whose surface syntax does not carry its
  operand's width (a "width eraser") left an anchor-free tree free to
  re-default. Instances beyond `drop`:
  - **`i32.wrap_i64` — live values changed.**
    `(i32.wrap_i64 (i64.shr_u (i64.const 4096) (i64.const 40)))` returns
    0; it decompiled to `4096 >>u 40` (simplify elided the redundant cast)
    and recompiled to `i32.shr_u` with the count masked to 8 — the export
    returned 16. Any anchor-free i64 tree with a non-mod-2^32-homomorphic
    op (`>>`, `/`, `%`) under a wrap; likewise **comparisons** and **`eqz`**
    (`(4096 >>u 40) == 0` flipped true→false).
  - **`trunc` source width**: `i64.trunc_f32_u (f32.const 16777217)` (the
    f32 rounds to 16777216) round-tripped to `i32.const 16777217;
    i64.extend_i32_u` = 16777217 — the trunc's cast pinned the result
    width, not the float source.
  **Fix — erasure made explicit in the `from_wasm` API** (`Stack`): the
  pop split into `pop_width_preserved` (the operand's width survives in the
  printed form — non-numeric operands, and arithmetic, whose result carries
  it) and `pop_width_erased` (drop/wrap/promote/demote), which pins any
  non-i32 opcode width with an identity cast; comparisons pin via
  `pop_tagged` + `pin_width`, and `int_un_op`'s `pin` covers `eqz` and the
  truncations (float source). Method-form ops (`clz`/`ctz`/`popcnt`/
  `rotl`/`rotr`, the float `abs`/`sqrt`/…/`min`/`max`, `neg`) bake their
  width in at the *receiver*, so they carry the receiver's flexibility to
  their result tag — an erasing consumer then pins the result, and that pin
  (a cast on the result) propagates back to the receiver (`((5).clz()) as
  i64` is `i64.clz`), fixing `wrap(rotl …)`, `drop(clz …)`, `eqz(rotl …)`.
  The width **tag now propagates grounding**: an arithmetic (or method)
  result is flexible (tagged, pinnable) only when its flexible-determining
  operand is — a grounded operand (a local, a call) makes the tree grounded,
  so `x + 1 == 2` and `2 == x + 1` are both cast-free while `(2^31 + 2^31)
  == 0` is pinned. `simplify`'s `load_bearing_literal` drops every redundant
  pin, so output stays clean (byte-identical binary, zero test churn; a
  bonus: wax now rejects invalid truncs/`eqz` it used to accept). Oracle
  coverage (`fuzz/PLAN.md` §9): `fuzz/drop-width.sh` gained the
  wrap/eqz/compare/trunc-source and method-form families (115 combos), and
  the `oracle.sh` histogram extended to shifts (catches the wrap bug's
  `i64.shr_u → i32.shr_u` on corpus inputs); comparisons/wrap/`eqz`/method
  forms stay out of the histogram — they drift harmlessly in dead code /
  fold legitimately, so the deterministic sweep guards them instead.

- **A few `typing.ml` asserts still crash on invalid input.** The `assert false` / `failwith` sites across `validation.ml`, `from_wasm.ml`, `to_wasm.ml`, and `typing.ml` were audited and classified as genuine invariants, unimplemented features, or bugs reachable on parseable-but-invalid input. The reachable bugs in `validation.ml` (subtype-relation and tag-type checks, typed `select`, non-function `func`/`start`/tag types) and `from_wasm.ml` (non-function/continuation type references, malformed constant expressions), plus the two worst in `typing.ml` (operand type mismatch, unbound branch label), now report diagnostics. The remaining reachable `typing.ml` crashes are all unimplemented Wax features (anonymous struct/array literal inference, block parameters in expression position, un-inferable `let`/`const` declarations — see section 2); everything else is a true invariant. Conversion passes can now `Diagnostic.abort` (report and stop) rather than continue into spurious failures; the validator stays report-and-continue, since under conditional modules it runs through `Cond_explore`, which collects each configuration's errors after the check returns.

## 2. Wax Language Completeness

| Feature | Status | Notes |
|---------|--------|-------|
| Block parameters | Rejected with a diagnostic | `block`/`loop`/`if` with params report `parameterized_block_expression` (`typing.ml`); a `Try` block still `assert (typ.params = [||])` |
| Module name | Supported | `#![module = "name"]` inner attribute; maps to the Wasm module name (the `$name` in `(module $name)` / the name section) |
| `dispatch` (br_table sugar) | Supported | First-class node modelling the conventional dense-switch lowering (one nested void block per case around a `br_table`, every case an arm including the trailing default, repeated/arbitrary index map). Lowered by `Ast_utils.lower_dispatch` (shared by typing and `to_wasm`); **recovered** from the block shape when decompiling WAT/WASM (`recover_dispatch.ml`), so jump tables round-trip byte-for-byte |
| `i++` / `for` / `while` / `do..while` | Not implemented | |
| `switch` statement | Not implemented | Sugar over `br_table` |
| Tuples as first-class values | Not planned | Multi-value uses native stack sequences; the binaryen tuple extension was removed |
| `include` (file inclusion) | Not implemented | |
| Conditional compilation | Supported | `#[if]`/`#[else]` parse, type-check per branch, and round-trip; see [notes](#conditional-compilation) |
| Trailing commas in blocks | Not allowed | |
| Two-step type inference | Not implemented | Overloading resolution |
| Comment preservation | Supported (wax↔wat) | Comments and blank lines survive the formatters and wax↔wat conversion (delimiters are translated); placement is approximate when a comment sits inside a fused/expanded construct. Lost only into/out of the WASM binary. |

### Conditional Compilation

Implemented. `#[if(...)]` / `#[else]` attributes (and the WAT-level `(@if ...)` annotations they correspond to) gate module fields — including `Group`s of fields — on compile-time conditions:

```rust
#[if(ocaml_version >= (5, 1, 0))]
fn memory_grow(n: i32) -> i32;
#[else]
fn memory_grow(pages: i32) -> i32 { mem.grow(pages); }
```

Conditions are versions (integer tuples) and `$name` variables combined with `all`/`any`/`not` and comparisons. They are **parsed, type-checked, round-tripped, and (optionally) evaluated** in every format. The type checker explores each reachable branch under its condition assumption (`A ∧ B`, `A ∧ ¬B`), so all branches are validated regardless of which flags would be active, and per-branch name resolution works (e.g. a name imported with a different signature in each branch). See the `cond-annot`, `cond-validation`, and `wax-conditional` cram tests.

**Flag-based selection** is implemented: the `-D`/`--define` CLI flag supplies variable bindings (`main.ml`, parsed via `Cond_specialize.parse_define`), and the field-filtering pre-pass `Cond_specialize.module_` (in both `lib-wasm` and `lib-wax`, run after parse in `specialize_wat`/`specialize_wax`) drops the unselected branches to emit a single concrete module. With no `-D` bindings the pre-pass is the identity, so conditions are preserved by default.

**Cross-format lowering** is implemented: the Wax `#[if]` (`Conditional`) and WAT `(@if)` (`Module_if_annotation`) forms convert in both directions (`from_wasm.ml`, `to_wasm.ml`), as do their instruction-level counterparts (`If_annotation`).

## 3. WebAssembly Spec Compliance

| Proposal | Status |
|----------|--------|
| MVP (1.0) | Fully supported |
| GC (WasmGC) | Supported; struct/array field validation (signage, field index) implemented |
| Exception handling (try_table) | Supported |
| Stack switching (typed continuations) | Supported (WAT/WASM and Wax) |
| Tail calls | Supported |
| Bulk memory | Supported |
| Reference types | Supported |
| Multi-memory | Supported |
| Memory64 | Supported |
| SIMD/v128 | Supported — round-trips through Wax as method/free-function intrinsics (`simd.ml`, `from_wasm.ml`, `to_wasm.ml`) |
| Relaxed SIMD | Supported — same path as SIMD |
| Threads/Atomics | Supported — shared memory, atomic loads/stores/RMW, `atomic.fence`, and `memory.atomic.wait`/`notify`; decompiled to Wax method intrinsics (`m.i32_atomic_rmw_add`, `atomic::fence()`, …) |
| Wide arithmetic | Supported — 128-bit integer ops (`i64.add128`, …) as `i64::` intrinsics |
| Branch hinting | Supported — `#[likely]`/`#[unlikely]` (the WAT `@metadata.code.branch_hint` annotation) |
| Custom page sizes | Supported — `pagesize` on a memory |
| Component Model | Not supported |
| Legacy exception handling | `try`/`catch`/`catch_all` supported — dedicated Wax `try { … } catch { … }` syntax, round-tripping through the legacy binary opcodes; `delegate` / `rethrow` are rejected |
| Tag result types | Permitted — the stack-switching proposal removes the MVP rule that tags must have empty results (suspend tags carry results), so that check is intentionally absent |

## 4. Conversion Fidelity (WAT/WASM to Wax)

Memories, tables, data and element segments, their imports, loads/stores, `tab[i]`
access, `call_indirect`, the bulk-memory/table-management instructions,
`array.new_data`/`new_elem`/`init_data`/`init_elem`, and all SIMD/v128 and
relaxed-SIMD instructions now decompile to dedicated Wax syntax — no instruction
is silently replaced with `unreachable`. The atomic (threads) instructions
decompile to Wax method intrinsics as well; `delegate`/`rethrow` are the only
exception-handling opcodes rejected rather than converted.

Some constructs round-trip as an equivalent form rather than byte-identically:
`call_indirect` is reconstructed from `(tab[i] as &$ft)(args)`, and an i64 narrow
load (`i64.load8_s`, …) comes back as the equivalent `i32` load + `i64.extend`.

## 5. Validation Hardening

- `ZZZ` placeholders remain (4 in `validation.ml`, 6 in `typing.ml`, ~15 across `src/`) — some WAT validation rules are incomplete (the `assert false` sites there now report diagnostics, but several use an imprecise `no_loc` source location). `failwith` is essentially gone (only 2, in `text_to_binary.ml`)
- `typing.ml` still crashes on a number of invalid Wax programs — the reachable `assert false` sites that remain are unimplemented features (see sections 1 and 2)
- `wasm -> wasm` pipeline skips validation entirely (commented out in `wasm_to_wasm`, `main.ml`)
- GC struct/array field validation (signage, field index) is implemented in `validation.ml`
- TryTable handler stack context is threaded (functional; minor cleanup notes remain)

## 6. Developer Tooling

### What's already present

- Formatter (wax-to-wax and wat-to-wat round-trips)
- Source maps (wax/wat to wasm only)
- Colored diagnostics with source snippets and "did you mean?" hints
- Pager integration for large output
- Stdin/stdout piping
- Format auto-detection from file extension

### LSP server

No language server exists. This is the single biggest gap for adoption — editors can't offer go-to-definition, hover types, inline errors, or completions for Wax files. The type checker and parser already exist; they need to be wired into the LSP protocol.

### Editor integration / syntax highlighting

No TextMate grammar, no tree-sitter grammar, no VS Code extension. Wax files get no syntax highlighting in any editor. A tree-sitter grammar would also enable a WASM-based parser for browser playgrounds.

### Watch mode

No `--watch` flag to recompile on file changes. Every edit requires a manual re-run.

### Structured error output

Errors go to stderr as human-readable text only. No `--error-format=json` for editor or CI consumption. Machine-readable diagnostics are a prerequisite for LSP and build system integrations.

### Exit codes

The toolchain defines 0 (success), 123 (CLI misuse — binary to terminal, format mismatch, multiple files without `--inplace`), and 128 (rejected input — parse/validation/type errors, malformed binary); cmdliner contributes 124 (command-line parse error) and 125 (internal error). The full set is documented in `docs/src/cli.md` and registered as cmdliner `~exits`, so `wax --help` lists it. There is still no finer distinction *within* 128 between parse, type, and I/O errors, so scripts cannot yet tell those apart.

### Multi-file support

No `include`, no module system, no way to compile multiple files together. Every invocation is single file in, single file out. This is also a blocker for conditional compilation being useful in practice.

### Source maps for non-binary output

Source maps only work for `*->wasm`. No mapping metadata when outputting WAT or Wax, which limits debugging of round-tripped code.

### Warnings

The diagnostic system has a warning severity and a configurable warning framework (`lib-utils/warning.ml`): warnings have stable names (`unused-local`, `truncated-coverage`, `naming-conflict`, …) and groups, and `-W NAME=hidden|warning|error` sets their level. The `unused-local` warning is emitted (a `let`-bound local never read), turned on by `--validate` and always under `check`. Other lints — shadowed bindings, unreachable code — are still not flagged.

### AST dump mode

No `--dump-ast` or `--dump-ir` flag to inspect internal representations. Useful for contributors and for building other tools on top of the compiler.

### Distribution

Besides the opam package, the CLI can be built as a single, cross-platform npm package via `wasm_of_ocaml` (the `wasm` executable mode + `npm/build.sh`): one `.wasm` module plus a Node loader, runnable on Linux/macOS/Windows Node (≥ 22, for WasmGC). A tag-gated GitHub workflow (`npm-package.yml`) builds, smoke-tests it across the OS matrix, and publishes — pending an `NPM_TOKEN` and a final package name.

## 7. Documentation

The mdbook (`docs/`) is broadly current: the language guide now covers
imports/exports, recursive and subtyped types, SIMD, stack switching, holes, and
the attribute system (including `#![module = "name"]`); the correspondence pages
cover the instruction/type/module-field mappings (including `dispatch`/`match`);
and a `features.md` page gives the proposal-support matrix (with the deliberate
tag-result relaxation). `language.md` and `introduction.md` code blocks are
compile-checked in CI (`docs-*.t`; `language.md` via an opt-in ```` ```wax,check ````
marker). Remaining gaps:

- No changelog or release notes
- No contributor guide
- No tutorial / cookbook, and known-limitations content is only partial (folded
  into `features.md`) — tracked in `ADOPTION.md`
- No blog post introducing Wax

## 8. Testing Gaps

There is now CI (`.github/workflows/`: build + `dune runtest` on an OS/OCaml
matrix, docs deploy, and an npm build/test/publish workflow), an extensive cram
suite (including CLI error cases and type errors), the WebAssembly spec suite,
and a differential/round-trip **fuzzing harness** (`fuzz/`) with crash,
round-trip, and idempotence oracles. Remaining gaps:

- No unit tests for individual type-checking rules (covered indirectly by cram + fuzzing)
- No tests for the `wasm -> wasm` pipeline (which also still skips validation)
- No tests for source-map generation
