# Verification plan for `Wasm_link` and `Wasm_source_map`

Plan to gain confidence in `compiler/lib-wasm/wasm_link.ml` (~2500 lines: binary
reader/writer, type canonicalisation, subtype checks, index remapping, section
rewriting) and `compiler/lib-wasm/wasm_source_map.ml` (streaming VLQ rewriting of
source map mappings).

## 1. Risk inventory

Where bugs can hide, and how visible they currently are:

| Area | Code | Currently visible? |
|---|---|---|
| Binary parsing / writing (LEB128, sections) | `Read`, `Write` modules | Yes — V8 rejects malformed modules when tests instantiate them |
| Rec-type canonicalisation across modules | `Read.RecTypeTbl`, structural hashing/equality | Mostly — wrong merging usually breaks validation, but *failing to merge* equivalent groups, or falsely merging α-equivalent ones, may validate and still be wrong or bloated |
| Import/export subtype checks | `subtype`, `heap_subtype`, `ref_subtype`, `check_limits`, `check_export_import_types` | Partially — too-lenient checks are masked when the engine re-validates; error paths (e.g. "export in a later module") are likely never exercised |
| Index remapping in code bodies | `Scan.scanner`, `Scan.func` | Yes — wrong indices almost always fail validation or tests |
| Byte-shift bookkeeping (LEB width changes) | `Scan.push_resize`, resize entries pushed in the code-section loop (`wasm_link.ml` ≈ lines 2296–2345) | **No** — only affects source maps; nothing checks them |
| Source map rewriting | `Js_source_map.resize_mappings` | **No** — output mappings are never validated |
| Name section rewriting (incl. indirect name maps) | `write_namemap`, `write_indirectnamemap` | **No** — engines silently ignore malformed custom sections |
| Export filtering (`~filter_export`) | index compaction after dropping exports | Partially — shrinking indices across LEB width boundaries is a rare path |

Key observation: because `make tests-wasm` in the dev profile uses separate
compilation, every wasm test already exercises the linker end-to-end and V8
validates every linked module. The *typed* parts of the output are therefore
reasonably well covered by existing tests. The blind spots are the two custom
outputs nobody validates — **source maps** and the **name section** — plus edge
cases that small test programs never reach.

## 2. Phase 1 — Property-based test of `Wasm_source_map.resize` (highest value/effort)

The streaming transducer in `resize_mappings` is the trickiest pure function
of the two modules, and it has a simple specification.

**Semantics to encode as the oracle** (from how `wasm_link.ml` builds
`resize_data`):

- `resize_data` is a sequence of `(pos, delta)` entries with strictly increasing
  `pos`, in input-file byte offsets.
- A mapping at generated column `col` is rewritten to
  `col + sum { delta_k | pos_k <= col }`.
- The first entry is always `(0, -code_section_start)` (input source map columns
  are file-relative; the output is code-piece-relative), so the *cumulative*
  delta can be negative even though the final column must stay non-negative:
  a segment whose shifted column would be negative is dropped from the output.
- Only the first VLQ field of each segment (generated column) changes; the
  remaining 0/3/4 fields pass through untouched.

**Implementation**:

- Write the naive reference: split mappings on `,`, decode each segment fully
  with `Vlq64`, apply the formula above, re-encode. O(n·m), obviously correct.
- QCheck generator for mappings: random count of segments (0–500), each with
  1, 4 or 5 fields; column deltas skewed towards small values but including
  large ones (to cross VLQ digit-count boundaries).
- QCheck generator for `resize_data`: strictly increasing positions, deltas in
  a range that keeps cumulative shifts consistent with what the linker produces
  (first entry negative, subsequent entries ≥ 0); include entries whose `pos`
  falls exactly on a mapping column, several entries between two consecutive
  mappings, and entries past the last mapping.
- Property: `resize_mappings data m` = reference on all inputs; also
  idempotence-style sanity checks (`resize` with empty `resize_data` is the
  identity — already special-cased, test the boundary `i = 1`).
- Adversarial fixed cases (unit tests, not random): empty mappings; a single
  segment; a mapping at column exactly `pos_0`; all mappings before the first
  effective resize point; segment at the very end without trailing `,`.

**Where**: follow the existing pattern in `compiler/tests-compiler/pbt/`
(`test_int31.ml` — QCheck + `inline_tests`, guarded by
`(enabled_if %{lib-available:qcheck})`; `qcheck` is already a `:with-test`
dependency in `dune-project`). Add `test_wasm_source_map.ml` there, with
`wasm_of_ocaml-compiler` added to the libraries. This may require exposing
`resize_mappings` (string → string) in `wasm_source_map.mli` for direct testing,
or testing through `resize` with a `Source_map.Standard.t` wrapper.

## 3. Phase 2 — Instruction-boundary invariant for linked source maps

End-to-end check of the *composition*: `Scan`'s shift recording +
`Wasm_source_map.resize` + `concatenate` offsets.

**Invariant**: linking never reorders, adds or drops instructions in function
bodies; it only changes the width of LEB-encoded immediates. So there is a 1:1
correspondence between instructions of each input module's code section and a
contiguous range of the output code section, and every input mapping
`(offset → src_loc)` must appear in the output as `(offset' → same src_loc)`
where `offset'` is the new offset of the *same* instruction.

**Checker tool** (new test executable, e.g.
`compiler/tests-wasm_of_ocaml/linker/check_sourcemap.ml`):

1. Decode the code section of each input module and of the linked output into
   lists of instruction start offsets. Two options:
   - reuse the internal decoder (`Scan` already walks instruction boundaries;
     expose a debug hook), or
   - shell out to `wasm-tools objdump`/`wasm-tools print -p` when available and
     parse offsets (keeps the checker independent of the code under test —
     preferable: a checker that shares the linker's decoder shares its bugs).
2. Align instruction k of input function j with its counterpart in the output
   (same order; function order is preserved per input module, functions are
   concatenated in input order).
3. Parse both source maps; assert that for every input mapping the corresponding
   output mapping exists, points at the aligned instruction's offset, and has an
   identical `(source, line, col, name)` tuple. Assert no output mapping points
   inside an instruction (i.e. all mapped offsets are instruction boundaries).

**Test inputs**: link the precompiled runtime + a couple of compiled test
modules with `--source-map`; this goes through
`compiler/bin-wasm_of_ocaml/compile.ml:803` / `link.ml:1166` naturally, or call
`Wasm_link.f` directly from the test.

**Cheaper complement** (independent, catches gross breakage): a wasm analogue of
`compiler/tests-sourcemap/` — compile a program with known source locations,
link with source maps, run under Node with `--enable-source-maps`, throw, and
snapshot-test that the stack trace resolves to the right `.ml` file/line.

## 4. Phase 3 — Name section round-trip

Engines ignore broken custom sections, so this needs an explicit test.

- Link modules whose inputs have rich name sections (module/function/local/type
  names — the runtime `.wasm` and any `--pretty`-ish build have these).
- Re-parse the linked output's name section (either with `Read` +
  `Scan.local_namemap`, or externally with `wasm-tools print` and grep the
  symbolic names) and assert:
  - every function kept in the output has the name it had in its input module,
    associated with the *remapped* index;
  - indirect name maps (local names) survive with correct outer (function) and
    inner (local) indices, including functions whose index moved across a LEB
    width boundary;
  - no dangling entries for functions removed by `~filter_export`/import
    resolution.
- Snapshot (`ppx_expect` or `.expected` file) on a small crafted pair of `.wat`
  inputs is enough; one large input (the runtime) as a smoke test.

## 5. Phase 4 — Crafted `.wat` unit tests for cliff edges

Small hand-written module pairs, assembled with the existing `wat_preprocess` /
Binaryen tooling, linked with `Wasm_link.f`, then validated externally
(`wasm-tools validate --features all`, and/or instantiated under Node). Cases:

**LEB128 width boundaries** (the only thing that produces non-trivial
`resize_data`, and the direct trigger for Phase-1/2 code):
- a module importing from another whose export indices land at 127/128 and
  16383/16384, so immediates grow when remapped;
- the shrinking direction: a module with >128 functions where
  `~filter_export` + resolved imports compact indices back below 128;
- type indices, global indices and function indices each crossing a boundary
  (they're rewritten by different `Scan` cases).

**Rec-type canonicalisation**:
- the same rec group textually duplicated in two modules → must be merged (check
  the output type section has one copy);
- two groups that are α-equivalent but ordered differently inside the group →
  must *not* be merged;
- self-referential subtypes, `sub final`, forward references within a group;
- a group merged with a third module that references it via import.

**Import/export matching** (`check_export_import_types` and friends):
- function import satisfied by an export of a *declared subtype* (must pass) and
  by an unrelated type (must fail with the right error);
- global: `mut` vs immutable, value subtyping for immutable globals;
- table/memory limits: import `min` smaller/larger than export, missing/present
  `max` (`check_limits`);
- tag imports;
- the ordering error path: import referring to an export of a later module
  (expected error message, `wasm_link.ml:2153`).

**Misc**:
- `start` functions in several modules (the `start_count > 1` synthesis path);
- data-count section present/absent combinations;
- a module with an empty code section / no exports.

Each case is a Cram test or `.expected`-based test under a new
`compiler/tests-wasm_of_ocaml/linker/` directory, so failures show readable
diffs.

## 6. Phase 5 — External validation wired into the test suite

- Add `wasm-tools validate --features all` (or
  `wasm-opt --all-features -o /dev/null` as fallback) on the linked output of
  the Phase-4/Phase-2 tests, guarded by `(enabled_if %{bin-available:...})`.
- Rationale: Node/V8 validation only covers modules the tests *instantiate* and
  only the feature set V8 implements; a standalone validator also diagnoses
  failures with offsets instead of a bare `CompileError`.

## 7. Phase 6 — Split-and-relink fuzzing

Random *linker inputs* are hard to generate directly; deriving them from random
valid modules gives realistic import graphs for free.

1. Generate random GC+EH modules with `wasm-tools smith` (enable the relevant
   proposals).
2. Mechanically split each module in two at a function-boundary cut: functions
   in part B that part A calls become A-imports/B-exports and vice versa;
   shared types are duplicated into both (exercising canonicalisation); shared
   globals/tables/memories exported from one side.
3. Relink with `Wasm_link.f`, validate the result, and compare against the
   original module: `wasm-tools print` both, normalise (index renumbering,
   type-section order) and diff — or at minimum check instruction-stream
   equality per function (same opcode sequence, immediates equal modulo
   remapping).
4. Run as a nightly/manual `dune` rule or a script under `tools/`, not in the
   default CI path; keep failing seeds as regression `.wat` files in Phase 4's
   directory.

The splitter is the main cost here (~a few hundred lines against `wasm-tools`
JSON/`wat` output, or reusing `Read`). Do it after Phases 1–5; skip if those
phases already surface enough.

## 8. Phase 7 — Differential testing against Binaryen's `wasm-merge`

`Binaryen.link` (`binaryen.ml:66`) already wraps `wasm-merge`, which implements
the same semantics and is still used on the whole-program path
(`compile.ml:182,253`). Use it as an oracle for the separate-compilation linker:

- For the Phase-4 inputs and a full separate-compilation build of the test
  suite: link the same module set with both `Wasm_link.f` and `wasm-merge`,
  check both validate, and run the resulting programs — outputs must match.
- Where feasible, compare structure: same export list, same import residue,
  equivalent type sections after canonicalisation (`wasm-merge` output passed
  through `wasm-opt --type-ssa`-free normalisation may differ; behavioural
  equality is the reliable check, structural diff is best-effort).
- Divergences are informative in both directions (a bug on either side, or a
  spec-interpretation difference worth documenting).

## 9. Phase 8 — Self-checks and coverage

- **Debug self-check mode**: extend the existing `Scan.debug` flag (or a
  `Debug.find "wasm-link"` section) so that after writing the output the linker
  re-parses it with `Read`, recomputes the interface, and asserts it equals the
  merged interface computed by `resolve` (exports = union of kept exports,
  imports = unresolved residue, types well-formed). Catches reader/writer
  disagreement at the point of failure instead of inside V8.
- **Coverage measurement**: one-off `bisect_ppx` run over `wasm_link.ml` +
  `wasm_source_map.ml` while running `make tests-wasm` (dev profile) and the
  Phase-4 tests. Expect the report to show unexercised section kinds, subtyping
  branches and error paths — use it to prioritise which Phase-4 cases still
  matter and to demonstrate when the plan is "done".

## 10. Suggested order and effort

| Phase | What | Effort | Why this order |
|---|---|---|---|
| 1 | QCheck oracle for `resize` | ~1 day | Least-observed, trickiest pure code; zero infrastructure needed |
| 2 | Instruction-boundary source map checker | 1–2 days | Covers the full source-map pipeline; doubles as regression net for `Scan` |
| 3 | Name section round-trip | ~½ day | Only way these bugs become visible at all |
| 4 | Crafted `.wat` cliff-edge tests | 1–2 days | Deterministic coverage of LEB boundaries, rec types, subtyping, error paths |
| 5 | External `wasm-tools validate` in tests | ~½ day | Cheap once Phase 4 exists |
| 8 | Self-check mode + bisect_ppx report | ~1 day | Tells you what's still dark |
| 7 | Differential vs `wasm-merge` | 1 day | Oracle for resolution semantics |
| 6 | Split-and-relink fuzzing | 2–4 days | Highest residual-bug yield, highest cost; decide after coverage report |

Phases 1–5 are the core; after them, every output the linker produces (typed
sections, source maps, name section) is checked by something other than the
code that produced it.
