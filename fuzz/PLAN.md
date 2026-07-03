# Fuzzing harness — improvement plan

*Drafted 2026-07-02 from a review of the harness (`README.md`, `oracle.sh`,
`lib.sh`, the campaign scripts, `fuzz_mutate.ml`). Ordered by expected
payoff; items 1–3 each target a subsystem with zero current coverage and
reuse `oracle.sh` unchanged.*

## 1. Add CLI-flag dimensions to the crash sweep  ✰ proven-miss

`oracle.sh` sweeps only `{-v, } × {wat, wax, wasm}`. The two confirmed
`folding.ml` crashes (see `INVARIANTS.md`) sit behind `--fold`/`--unfold`,
which no campaign ever passes — a converged campaign missed live bugs for
exactly this reason.

- [ ] Extend the sweep in `oracle.sh` with fold modes for text output
      (`--fold`, `--unfold` on `-f wat`, and on `-f wax` if applicable).
- [ ] Include the other wiring paths: `wax format` (distinct code path in
      `main.ml`), `-s` (strict validate), `-W all=error`.
- [ ] Avoid the full cross-product: pick ONE random flag combination per
      input per run (swarm testing). Over a campaign this finds the same
      bugs at ~no extra cost. Derive the choice from the input's hash or a
      passed seed, not `$RANDOM`, so findings replay.
- Ready-made regression inputs (should become cram tests too):
  - `(module (func $f (call $undef)))` + `--fold` → `folding.ml:127` assert
  - `(module (type $s (struct)) (func $f (type $s)))` + `--fold` →
    `folding.ml:264` assert

## 2. Fuzz conditional compilation  ✰ largest unfuzzed subsystem

`build-corpus.sh` skips `(@if)` files; nothing generates `#[if]`/`-D`.
`Cond_explore` / `Cond_specialize` / `cond_solver.ml` are entirely dark.

- [ ] Write a small wrapper-mutator (extend `fuzz_mutate.ml`, or a separate
      pass) that wraps random module fields / field groups in
      `#[if(<random condition>)]` (+ optional `#[else]`), with conditions
      drawn from a few variables, versions, `all`/`any`/`not`, comparisons.
- [ ] Oracle (a): the existing crash sweep, run under random `-D` bindings.
- [ ] Oracle (b) — commutation: `wax -D x=… -f wasm m.wax` must equal
      (semantically: both validate; optionally `wasm-tools print` equality)
      compiling the pre-specialized module (specialize → then compile with
      no `-D`).
- [ ] Oracle (c) — exhaustive for ≤3 variables: for each full assignment,
      the specialized module validates iff the all-configurations check
      (`--validate` with conditions kept) accepted that configuration.

## 3. Fuzz comment preservation  ✰ headline feature, zero coverage

The corpus is comment-free (smith output, wax's own decompiled output), so
the trivia machinery always runs on empty input.

- [ ] A text pass that sprinkles `;;`, `(; ;)` (wat) / `//`, `/* */` (wax)
      and blank lines at random token boundaries into wat/wax seeds.
- [ ] Run the existing crash + idempotence oracles on the result.
- [ ] New cheap invariant: the comment count (count of comment tokens, or
      of unique sentinel strings planted by the mutator) never DECREASES
      across format or wax↔wat conversion — no comment silently dropped.
      Planting unique sentinels (`;;C17`) makes the check a grep.

## 4. Adopt `wasm-tools mutate` and `wasm-tools shrink`

wasm-tools is already a hard dependency of the harness.

- [ ] Replace/augment `mutate-wasm.js`'s blind byte flips with
      `wasm-tools mutate` — structure-aware mutants get past the section
      parser into validation and `from_wasm` on the TRUSTED binary path
      (the unvalidated-input surface).
- [ ] `wasm-tools mutate --preserve-semantics` + the execution oracles =
      behavioural-equivalence fuzzing on arbitrary smith modules. Today
      miscompilation detection exists only where spec `.wast` assertions
      exist; this removes that ceiling. (Baseline run vs. run after wax
      recompilation, same differential structure as `exec-ref.sh`.)
- [ ] Auto-minimize findings: `wasm-tools shrink` with predicate = "the
      oracle still reports the same finding signature" for `.wasm`
      findings; for `.wax` findings a greedy ddmin loop reusing
      `fuzz_mutate`'s delete/statement mutations (~50 lines).

## 5. CI wiring + replayable campaigns

- [ ] Per-PR deterministic tier: `cast-lattice.sh` + `run.sh` over the
      corpus (the scripts already exit non-zero on HIGH findings, by
      design — they were built to gate).
- [ ] Nightly/weekly budgeted tier: `smith.sh`, `mutate-wax.sh`,
      `mutate-wat.sh`, `mutate-wasm.sh`, `diff-validate.sh`, plus the
      execution oracles (`exec-ref.sh` at least — currently NO aggregate
      runner invokes them; they only run when someone remembers).
      Upload findings dirs as workflow artifacts.
- [ ] Master seed: `mutate-wasm.sh` uses `$RANDOM` per mutation, so a
      campaign is not reproducible even though findings are re-verified.
      Thread an explicit `SEED` env through all workers (`fuzz_mutate`
      already accepts one; derive per-worker seeds as `SEED+i`).

## 6. Coverage: measure first, then guide

- [ ] One-off `bisect_ppx` build; run a full campaign; read the report for
      `validation.ml` / `typing.ml` / `folding.ml` arm coverage. This turns
      "which generator next?" into a data question (it would have shown
      folding.ml at 0% instantly).
- [ ] Then the README's roadmap item: a dune profile with
      `-afl-instrument` (native OCaml AFL support) and `afl-fuzz` on the
      binary reader (`-i wasm`) with `fuzz/corpus/valid` as seeds — the
      textbook AFL target here.

## 7. Differential WAT parsing

`VALIDATOR_DIFF` is gated on `FMT = wasm` (`oracle.sh:77`) and
`mutate-wat.sh` hunts only crashes, so wax's WAT parser verdicts are never
compared to anything.

- [ ] Extend the differential check to `.wat` inputs — wasm-tools parses
      wat directly (accept/reject parity on parse + validate).
- [ ] Aim it at the known-divergence-prone corners: edge numeric literals,
      NaN payloads, string escapes (feed `mutate-wat.awk`'s output through
      the diff, not just the crash oracle).

## 8. Resource-limit stress (`stress.sh`)

Nothing generates pathological inputs; OCaml recursion makes
`Stack_overflow` a real crash class for parser, typer, and printer.

- [ ] Deterministic generator growing NESTING depth (blocks, folded parens,
      nested expressions) in all three formats until clean-rejection or
      crash; assert never-crash, and pin the intended limits.
- [ ] Same for width: huge label lists (`br_table`), enormous
      literals/strings, very many locals/functions.
- [ ] `classify_wax` already classifies the failures (signal/exit-2);
      only the inputs are missing.

## 9. Oracle gap: semantics-changing round-trips (width drift)

The dropped-expression width-drift bug (bug + fix design in `ROADMAP.md`
§1) is invisible to every validity oracle — both sides validate; only
execution sees the introduced trap. Harness follow-up:

**2026-07-03 update — the class generalized and is now fixed** (`ROADMAP.md`
§1 "width-eraser drift"): wrap/compare/eqz over anchor-free i64 trees with
non-homomorphic ops changed LIVE values (`wrap(4096 >>u 40)`: 0 → 16), and
trunc's float source width drifted. Fixed via the explicit
`pop_width_preserved`/`pop_width_erased` split with grounding-propagating
tags (see `ROADMAP.md` §1). The sweep and histogram oracle below were
extended to the new families accordingly.

- [x] Small deterministic sweep (cast-lattice-style): dropped
      width-sensitive trees (`div`/`rem`, both widths, all-literal
      operands around the 2^31/2^32 boundaries), asserting the
      round-tripped wat preserves the operation width.
      → `fuzz/drop-width.sh` (wax-only, no wasm-tools; wired into
      `fuzz/check.sh`). Round-trips `wat → wax → wat` and asserts the
      load-bearing opcode survives at its width. Extended to the whole
      width-eraser class: each eraser (`drop`, `wrap`, `eqz`, `==`, `<u`)
      wrapping a width-sensitive i64 tree — both symbol-form
      (`div`/`rem`/`shr`/`shl`) and method-form (`rotl`/`rotr`/`clz`/`ctz`/
      `popcnt`) — plus the trunc-source family (both float widths, boundary
      consts). 115 combinations; verified it bites — neutering the pins
      turns up 55–66 findings; clean with the fix.
- [x] Confirm `exec-mutate.sh`/`exec-ref.sh` (MODE=wax) actually flag the
      class — a trap/no-trap divergence must fail the behavioural diff,
      not be skipped.
      → Confirmed. A dropped op traps unconditionally when its divisor
      narrows to 0, so an `assert_return` over the enclosing function
      diverges. `MODE=wax fuzz/exec-ref.sh` on a fixture
      (`(func (export "f") (result i32)`
      `  (drop (i64.div_u (i64.const 1)`
      `    (i64.add (i64.const 2147483648) (i64.const 2147483648))))`
      `  (i32.const 42))` + `(assert_return (invoke "f") (i32.const 42))`)
      reports `tested 1 / skipped 0 / norecompile 0` — exercised via wax,
      not skipped — and `regressions 1` ("integer divide by zero") against
      a neutered wax, `0` against the fixed one. So a real drift would fail
      the diff, not slip through.
- [x] Static width-preservation oracle in `oracle.sh`'s round-trip step
      (generalizes the sweep to arbitrary corpus/smith/mutant inputs,
      which carry no assertions): compare the trap-relevant opcode
      histogram of original vs `via.wasm` —
      `wasm-tools print | grep -oE
      'i(32|64)\.(div|rem)_[su]' | sort | uniq -c` — HIGH on any mismatch.
      → Added as a third branch of oracle 5 (`width_op_histogram`): runs
      only once `via.wasm` recompiled *and* validated, skips silently when
      the reference cannot print the original (no ground truth). Covers
      **div/rem, the shifts (shl/shr), and the (non-saturating) float→int
      truncations** — the shift family catches the `i32.wrap_i64` live bug
      via its `i64.shr_u → i32.shr_u` drift. Verified false-positive-free
      over the corpus (298 width-sensitive files: **0** findings with the
      fixes), it fires on a neutered wax, and it catches the class on inputs
      the exec oracles can't (no assertions). Comparisons, `eqz` and
      `i32.wrap_i64` themselves are *excluded* from the histogram: they
      drift harmlessly in dead code (`f32.eq → i32.eq` over holes) or fold
      legitimately (`i32.wrap_i64 (i64.extend_i32_u x)` = x), so they are
      not histogram-clean; the deterministic sweep guards them instead.

      Bringing `trunc_f{32,64}` in first required fixing a second, distinct
      width-drift: a truncation's *source float* width. Enabling the trunc
      families initially fired on 66 corpus modules, *none* a div/rem
      change — every one a trunc source drifting f32→f64 (a bare float
      operand re-defaults to f64) or an integer-valued float const dropping
      to an integer literal. Most were behaviourally benign (an f32 value
      promotes to f64 exactly), but some were genuine miscompilations —
      `i64.trunc_f32_u (f32.const 16777217)` (the f32 rounds to `16777216`)
      round-tripped via `wat → wax` to `i32.const 16777217;
      i64.extend_i32_u` = `16777217`. Fixed below; all 66 now zero.

- [x] Pin a truncation's float source in `from_wasm` (the `Trunc`/`TruncSat`
      arms of `int_un_op`: an inlined operand was returned bare, so its
      width took the trunc's *result* type, not the float source — the same
      unpinned-literal shape the `Drop` fix addressed).
      → New `pin_float` helper wraps an inlined operand in `(… as fXX)`
      (mirroring `Reinterpret`); `simplify` drops the pin when the operand
      already settles on that width (a plain f64 literal), so only f32
      sources and integer-valued float consts gain it. `trunc_f` re-added to
      `width_op_histogram`; the 66 corpus cases are now 0. Bonus: wax now
      *rejects* invalid truncs it used to accept — `i64.trunc_f32_s
      (i32.const 0)` decompiles to `(0 as i32) as f32 …`, and there is no
      implicit i32→f32, so five "type-checking should have failed" entries
      dropped from `wasm_test_suite.expected`. Cram test
      `number-trunc-to-i32.t` updated (source width now pinned, no longer
      drifts to f64).

- [x] Generalize to the full width-eraser class (`ROADMAP.md` §1): the
      `pop_width_preserved`/`pop_width_erased` split, grounding-propagating
      tags, pins for `wrap`/`promote`/`demote`/comparisons/`eqz`, and
      method-form ops (`clz`/`rotl`/`sqrt`/…) tagging their result with the
      receiver's flexibility so an eraser's pin propagates back to the
      receiver. Extended `drop-width.sh` (now 115 combos, catches 55–66 on a
      neutered build) and added shifts to `width_op_histogram` (FP-free over
      298 corpus files; catches the wrap live bug via `i64.shr_u`). Method
      forms and comparisons stay out of the histogram (dead-code /
      legitimate-fold noise) — the deterministic sweep guards them.

## Small fixes noticed in passing

- [ ] `oracle.sh:112` — the IDEMPOTENCE finding's repro command is a
      literal placeholder (`diff <(...) <(...)`); emit the real commands.
- [ ] `run.sh` should mention (or gain flags for) the exec oracles so the
      nightly tier is one entry point.

## Cross-references

- `AUDIT.md` — CI gap, exit-code contract, `--source-map-file` silently
  ignored on text outputs (fix or reject before fuzzing that flag).
- `INVARIANTS.md` — the folding.ml crash class this plan's item 1 targets;
  repro inputs listed there and above.
