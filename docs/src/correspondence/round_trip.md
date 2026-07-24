# Round-Tripping

Decompiling a Wasm module to Wax and recompiling it (`wasm → wax → wasm`)
reproduces the original module. This page states what that round trip preserves
exactly and enumerates the few places where it diverges. Every divergence is
semantically inert: the recompiled module behaves identically, it just is not
byte-for-byte identical.

## Preserved exactly

For nearly everything, the instruction stream round-trips opcode-for-opcode:

- Arithmetic, comparisons, and their operand widths.
- Loads and stores, including their memargs (offset and alignment).
- Calls. A `call_indirect` decompiles through a table access and re-fuses to
  the same instruction.
- GC struct and array operations.
- Structured control flow. The `while`, `match`, and `dispatch` recoveries
  (`recover_loops.ml`, `recover_match.ml`, `recover_dispatch.ml`) are exact
  inverses of their lowerings, so the loops, matches, and branch tables they
  reconstruct re-lower byte-for-byte.
- `nop` and `drop`.
- Constants, each pinned to its declared width (an `i64.const` stays an
  `i64.const`, not a re-defaulted `i32.const`).

Dead code is preserved too. Instructions after an `unreachable` (or another
terminator) have operands the surface syntax cannot type on its own, so the
decompiler pins them: a width-sensitive numeric operand is ascribed its opcode
width (`(_ as i64) + _`) instead of re-defaulting to `i32`, a `ref.eq` on the
polymorphic bottom pins one operand with `(_ as &?eq)`, and a `ref.is_null` on
the bottom pins its operand with `(_ as &?any)`. The opcodes after the
terminator keep their types across the round trip.

## Divergences

Each of the following is a normalisation, not a change in behaviour.

1. **Locals and names.** Local order and numbering are not preserved; every use
   is rewritten consistently. The `name` section is rewritten. The type section
   may be deduplicated and renumbered.

2. **`eq` then `eqz` fuses to `ne`.** A `t.eq` followed by `i32.eqz` decompiles
   to `a != b`, which recompiles as a single `t.ne`.

3. **Narrow load then widen fuses.** A narrow load immediately widened to `i64`
   (`i32.load8_s; i64.extend_i32_s`, and the `load16` / unsigned / atomic forms)
   decompiles to a single-cast `m.load8(x) as i64_s` and recompiles to the fused
   `i64.load8_s`. The fusion is a peephole in the recompiler (`to_wasm`), shared
   with hand-written Wax, not a decompiler rewrite, so it is the one divergence
   `--faithful` cannot remove: the faithful decompile emits the two-cast
   spelling `as i32_s as i64_s`, which the peephole re-fuses on the way back.

4. **Redundant `ref.cast` erased.** A `ref.cast` decompiles to an `as`
   ascription. While re-typing the decompiled Wax, the ascription is dropped
   whenever the operand's inferred type is already a subtype of the target, that
   is an identity cast or an upcast, so it recompiles to no instruction. A
   genuine downcast, where the operand's type is not a subtype of the target,
   is kept and re-emits `ref.cast`. A handful of ascriptions are load-bearing
   and are never dropped even when they look redundant: one pinning an abstract
   numeric literal to a non-default width, one on a bare `null` or a bottom
   reference whose consumer needs the named type, and a continuation ascription
   that names a different type than the operand's own (kept because it selects
   the instruction's type immediate; it emits no instruction of its own). This
   drop happens only on the decompilation path; a cast written by hand in Wax is
   always kept.

5. **Flat cast-dispatch chains are canonicalised.** Hand-written GC code often
   takes a value apart with a flat run of `br_on_cast_fail` blocks, one
   discarded block per arm. That flat chain is recovered as a `match`, which
   re-lowers to the nested `br_on_cast` ladder rather than the flat chain, so
   the round trip is semantically faithful but not byte-for-byte. (The nested
   ladder shape itself round-trips byte-for-byte.)

6. **A typed `select` may lose its immediate.** The value type is always
   preserved through the arms, but the explicit `(result t)` immediate form is
   not guaranteed to be reproduced.

## Faithful round-tripping

The `--faithful` flag (wax output only) turns off the two stream-reshaping
recoveries that it can turn off cleanly, so a decompiled module recompiles with
the same reachable instruction structure. It reliably suppresses divergences 2
and 5: `eq` then `eqz` stays `!(a == b)` (re-lowering to the `eq; eqz` pair,
not fused to `t.ne`), and a flat `br_on_cast_fail` chain is kept as separate
blocks (not recovered to a `br_on_cast` ladder). For divergence 4 it keeps a
redundant *non-null* `ref.cast` as an `as` ascription (re-emitting it), a
best-effort improvement (see below). It also pins a constant's width through an
`int`-to-`float` conversion and through `i64.extend32_s`. The Wax is pin-noisier
(a kept width ascription emits no instruction) but structurally exact.

Several normalisations remain even under `--faithful`, all semantically inert
(and each present on the default path too — `--faithful` does not make anything
worse). They fall outside the two recoveries the mode gates:

- **Locals and names** (divergence 1), a typed `select`'s immediate (divergence
  6), and constant *widths* (a small `i64` constant re-defaults to `i32`; its
  value is unchanged, a large one keeps `i64`).
- **Recompiler-peephole fusions** (divergence 3, generalised): narrow-load-then-
  widen (`i32.load8_s; i64.extend_i32_s` → `i64.load8_s`), `i64.extend32_s`
  (`wrap` + `extend`), and calling a `ref.func` directly (`ref.func; call_ref` →
  `call`). They live in the recompiler, shared with hand-written Wax, so the
  decompiler cannot avoid them.
- **Compiler-inserted casts.** The decompiler pins a member-access receiver and
  a `call_ref` callee with a `ref.cast` to a nullable reference; those pins are
  indistinguishable from a redundant source `ref.cast` to a nullable type
  without provenance, so faithful's cast fidelity is best-effort — it keeps a
  redundant *non-null* up-cast but prunes the nullable ones. Also
  `f32.neg`/`f64.neg` of a literal folds into the negated literal (Wax spells a
  negative float literal `-X`).
- **Dead code** (after an `unreachable` or an unconditional `br`): its operand
  stack is polymorphic, so the surface cannot always type it — a dead
  `i32.wrap_i64` drops, a dead constant re-defaults its width, a dead `call_ref`
  callee gains a `ref.cast`. None of it runs.

This mode's contract — that a faithful decompile+recompile reproduces the
reachable instruction *structure* (opcodes, order and count, modulo those inert
normalisations) — is enforced by the differential fuzzing harness (the
`FAITHDRIFT` leg), which compares the reachable opcode sequence with widths, the
compiler-cast family, and the fusions above normalised away.

## How this is checked

These guarantees are enforced by a differential fuzzing harness that compares
per-opcode histograms across a round trip, over both a curated corpus and a
`wasm-smith` campaign.
