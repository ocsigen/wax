# Verification plan for `Wasm_link` and its source-map handling

Plan to gain confidence in `src/lib-link/wasm_link.ml` (~2200 lines: binary
reader/writer, type canonicalisation, subtype checks, index remapping, section
rewriting) and `src/lib-link/source_map.ml` (streaming VLQ rewriting of source
map mappings). The linker is reached through the `wax link` CLI subcommand,
which calls `Wax_linker.Wasm_link.f`; the base64-VLQ codec it relies on lives in
`Wax_utils.Source_map.Vlq64`.

**Status.** Phases 1–3 are implemented (`test/pbt/test_source_map.ml`,
`test/check-sourcemap/` + `test/cram-tests/link.t`, and
`test/cram-tests/link-name-section.t`); the spec suite's linking cases run
through `src/bin/run_link_testsuite.ml` (golden `test/link_suite*.expected`).
Phases 4–8 are the remaining, roughly-ordered work.

## 1. Risk inventory

Where bugs can hide, and how visible they currently are:

| Area | Code | Currently visible? |
|---|---|---|
| Binary parsing / writing (LEB128, sections) | `Read`, `Write`, `Scan.scanner` | Yes — the built-in validator (`wax -v`) and `wasm-tools validate` reject malformed output |
| Rec-type canonicalisation across modules | `Read.add_rectype`, `types_store` / `output_table`, structural hashing/equality | Mostly — wrong merging usually breaks validation, but *failing to merge* equivalent groups, or falsely merging α-equivalent ones, may validate and still be wrong or bloated |
| Import/export subtype checks | `subtype`, `val_subtype`, `reftype_eq`, `valtype_eq`, `type_id_eq`, `check_limits`, `check_export_import_types` | Partially — too-lenient checks are masked when the output is re-validated; error paths (e.g. "export in a later module") need explicit tests |
| Index remapping in code bodies | `Scan.scanner`, `Scan.func`, `build_mappings` | Yes — wrong indices almost always fail validation or tests |
| Byte-shift bookkeeping (LEB width changes) | `Scan.push_resize`, the resize entries pushed in the code-section loop of `f` | **No** — only affects source maps; covered now by Phase 1/2, nothing else checks them |
| Source map rewriting | `Source_map.resize_mappings` | Now checked by Phase 1 (PBT) and Phase 2 (boundary checker) |
| Name section rewriting (incl. indirect name maps) | `write_namemap`, `write_indirectnamemap`, `write_simple_namemap` | Now checked by Phase 3 (round-trip through the disassembler) |
| Export filtering (`~filter_export`) | index compaction after dropping exports | Partially — shrinking indices across LEB width boundaries is a rare path |

Key observation: the linked output is validated only where a test explicitly
runs `wax -v` (or an external validator) on it. `test/cram-tests/link.t` does
this for several cases, and `run_link_testsuite.ml` drives the spec suite's
`register` / `assert_unlinkable` cases. The blind spots are the outputs nobody
validates by construction — the **name section** — plus edge cases small test
programs never reach (LEB-width boundaries, forward references, rare subtyping
arms).

## 2. Phase 1 — Property-based test of `Source_map.resize` — **done**

The streaming transducer in `resize_mappings` is the trickiest pure function of
the two modules, and it has a simple specification. Implemented in
`test/pbt/test_source_map.ml` (run under the `runtest` alias, `qcheck`
dependency): a naive reference (`naive_resize_mappings`, split on `,`, full
`Vlq64.decode_l` per segment, re-encode) checked against the streaming
`resize_mappings` over QCheck-generated mappings and `resize_data`.
`resize_mappings` is exposed in `source_map.mli` for this test.

**Semantics the reference encodes** (from how `wasm_link.ml` builds
`resize_data`):

- `resize_data` is a sequence of `(pos, delta)` entries with strictly increasing
  `pos`, in input-file byte offsets.
- A mapping at generated column `col` is rewritten to
  `col + sum { delta_k | pos_k <= col }`.
- The first entry is always `(0, -code_section_start)` (input source map columns
  are file-relative; the output is code-piece-relative), so the *cumulative*
  delta can be negative even though the final column must stay non-negative:
  a segment whose shifted column would be negative is dropped, and its
  source/original fields are folded into the next survivor.
- Only the first VLQ field of each segment (generated column) changes; the
  remaining 3/4 fields pass through untouched.

Adversarial fixed cases worth keeping alongside the random ones: empty mappings;
a single segment; a mapping at column exactly `pos_0`; all mappings before the
first effective resize point; a segment at the very end without a trailing `,`.

## 3. Phase 2 — Instruction-boundary invariant for linked source maps — **done**

End-to-end check of the *composition*: `Scan`'s shift recording +
`Source_map.resize` + `concatenate` offsets. Implemented as the checker
executable `test/check-sourcemap/check_sourcemap.ml`, driven from
`test/cram-tests/link.t` ("Link two modules with source maps and verify
instruction boundaries match").

**Invariant**: linking never reorders, adds or drops instructions in function
bodies; it only changes the width of LEB-encoded immediates. So there is a 1:1
correspondence between instructions of each input module's code section and a
contiguous range of the output code section, and every input mapping
`(offset → src_loc)` must appear in the output as `(offset' → same src_loc)`
where `offset'` is the new offset of the *same* instruction.

The checker decodes instruction start offsets with
`Wasm_link.get_instruction_offsets` (a `Scan` walk with `mark_instructions`)
for each input and for the linked output, aligns them, and asserts the mapped
columns land on aligned instruction boundaries with identical source locations.

**Cheaper complement still worth adding** (independent, catches gross breakage):
compile a program with known source locations, link with source maps, run under
Node with `--enable-source-maps`, throw, and snapshot-test that the stack trace
resolves to the right file/line.

## 4. Phase 3 — Name section round-trip — **done**

Engines ignore broken custom sections, so this needs an explicit test.
Implemented as `test/cram-tests/link-name-section.t`: two richly-named modules
are linked and the names read back with the disassembler (`-f wat`), which
decodes the name section through `from_wasm` — an independent path from the
linker's writer. The test asserts:

- every function/type/field/global/table/memory/tag kept in the output carries
  its input name at the *remapped* index (the second module's definitions land
  after the first's, so its indices genuinely move);
- indirect name maps survive with correct outer (function) and inner indices —
  locals *and* labels, which the disassembler now prints after
  `ebee8640` (both go through `write_indirectnamemap`, so remapping the outer
  index is exercised for the same code that handles labels);
- a resolved import leaves a single name, no dangling duplicate;
- function names whose *output* index crosses the 128 LEB-width boundary still
  round-trip (a 130-function module shifted up by a small one).

A larger smoke input (e.g. the standard library) could still be added, but the
crafted pair already exercises every subsection the disassembler surfaces.

## 5. Phase 4 — Crafted `.wat` unit tests for cliff edges — **partial**

`link.t` and `run_link_testsuite.ml` already cover: duplicate exports,
incompatible import/export types, import loops, branch-hint merging, name-aware
type coalescing (`--distinct-named-types`), and forward global references (both
directions, table and global initializers). What is still missing are the
LEB-width boundary cases and the finer subtyping/canonicalisation arms below.

**LEB128 width boundaries** (the only thing that produces non-trivial
`resize_data`, and the direct trigger for Phase-1/2 code):
- a module importing from another whose export indices land at 127/128 and
  16383/16384, so immediates grow when remapped;
- the shrinking direction: a module with >128 functions where
  `~filter_export` + resolved imports compact indices back below 128;
- type, global and function indices each crossing a boundary (they're rewritten
  by different `Scan` cases).

**Rec-type canonicalisation**:
- the same rec group textually duplicated in two modules → must be merged (check
  the output type section has one copy);
- two groups that are α-equivalent but ordered differently inside the group →
  must *not* be merged;
- self-referential subtypes, `sub final`, forward references within a group;
- a group merged with a third module that references it via import;
- descriptor/`describes` clauses (custom-descriptors): two structs differing only
  in their descriptor must stay distinct (`to_normalized_subtype` keeps them in
  the identity).

**Import/export matching** (`check_export_import_types` and friends):
- function import satisfied by an export of a *declared subtype* (must pass) and
  by an unrelated type (must fail with the right error);
- exact function imports (custom-descriptors): the conservative rejection path
  documented in `TODO.md` and the linker suite's `exact-func-import.wast`;
- global: `mut` vs immutable, value subtyping for immutable globals;
- table/memory limits: import `min` smaller/larger than export, missing/present
  `max`, and the address-type / page-size / shared mismatches in `check_limits`;
- tag imports.

**Misc**:
- `start` functions in several modules (the `start_count > 1` synthesis path);
- data-count section present/absent combinations;
- a module with an empty code section / no exports.

Each new case is a cram test under `test/cram-tests/`, so failures show readable
diffs.

## 6. Phase 5 — External validation wired into the tests — **partial**

`link.t` runs `wax -v` on several linked outputs. To harden this:
- add `wasm-tools validate --features all` on the linked output of the Phase-4
  cases, guarded by `(enabled_if %{bin-available:wasm-tools})`;
- rationale: the built-in validator and a second, independent one disagree
  exactly where a bug hides, and `wasm-tools` diagnoses failures with offsets
  instead of a bare error.

## 7. Phase 6 — Name/reader/writer self-check mode — **todo**

Add a debug self-check (extend `Scan.debug`, or a dedicated debug category) so
that after writing the output the linker re-parses it with `Read`, recomputes
the interface, and asserts it equals the merged interface computed during
resolution (exports = union of kept exports, imports = unresolved residue, types
well-formed). This catches reader/writer disagreement at the point of failure
instead of downstream. A one-off `bisect_ppx` run over `wasm_link.ml` +
`source_map.ml` while running `dune runtest` would show which section kinds,
subtyping branches and error paths are still unexercised, to prioritise Phase 4.

## 8. Phase 7 — Differential testing against an external merge tool — **todo**

Binaryen's `wasm-merge` implements the same separate-linking semantics and can
serve as an oracle (this repo does not wrap it; it would be an external tool
gated on availability). For the Phase-4 inputs: link the same module set with
both `Wasm_link.f` and `wasm-merge`, check both validate, and run the resulting
programs — observable behaviour must match. Structural comparison (export list,
import residue, canonicalised type sections) is best-effort; behavioural
equality is the reliable check. Divergences are informative in both directions —
`TODO.md` already records two (forward-global rejection, exact-import
conservatism) where the linker deliberately differs from `wasm-merge`.

## 9. Phase 8 — Split-and-relink fuzzing — **todo**

Random *linker inputs* are hard to generate directly; deriving them from random
valid modules gives realistic import graphs for free.

1. Generate random GC+EH modules with `wasm-tools smith` (the fuzzing harness
   already uses `wasm-smith`; see `fuzz/`).
2. Mechanically split each module in two at a function-boundary cut: functions
   in part B that part A calls become A-imports/B-exports and vice versa; shared
   types are duplicated into both (exercising canonicalisation); shared
   globals/tables/memories exported from one side.
3. Relink with `Wasm_link.f`, validate the result, and compare against the
   original: `wasm-tools print` both, normalise (index renumbering, type-section
   order) and diff — or at minimum check instruction-stream equality per function
   (same opcode sequence, immediates equal modulo remapping).
4. Run as a manual/nightly rule, not the default CI path; keep failing seeds as
   regression `.wat` files under `test/cram-tests/`.

The splitter is the main cost here. Do it after the cheaper phases; skip if they
already surface enough.

## 10. Suggested order and effort

| Phase | What | Status | Effort |
|---|---|---|---|
| 1 | QCheck oracle for `resize` | done | — |
| 2 | Instruction-boundary source map checker | done | — |
| 3 | Name section round-trip | done | — |
| 4 | Crafted `.wat` cliff-edge tests | partial | 1–2 days |
| 5 | External `wasm-tools validate` in tests | partial | ~½ day |
| 6 | Self-check mode + `bisect_ppx` report | todo | ~1 day |
| 7 | Differential vs `wasm-merge` | todo | 1 day |
| 8 | Split-and-relink fuzzing | todo | 2–4 days |

Phases 4–5 are the core remaining work; after them, every output the linker
produces (typed sections, source maps, name section) is checked by something
other than the code that produced it.
