# Round-Tripping

Decompiling a Wasm module to Wax and recompiling it (`wasm → wax → wasm`)
reproduces the original module. This page states what that round trip preserves
exactly and enumerates the few places where it diverges. Every divergence is
semantically inert: the recompiled module behaves identically, it just is not
byte-for-byte identical.

## Preserved exactly

For nearly everything, the instruction stream round-trips opcode-for-opcode:

- Arithmetic, comparisons, and their operand widths.
- Loads and stores, including their memargs (offset and alignment). A narrow
  load immediately widened to `i64` round-trips too: a genuinely fused
  `i64.load8_s` stays fused, and a hand-written `i32.load8_s; i64.extend_i32_s`
  pair stays a pair (see the shared-spelling note below for the one exception,
  the 32-bit form).
- Calls. A `call_indirect` decompiles through a table access and re-fuses to
  the same instruction.
- GC struct and array operations.
- Structured control flow. The `while`, `match`, and `dispatch` recoveries
  (`recover_loops.ml`, `recover_match.ml`, `recover_dispatch.ml`) are exact
  inverses of their lowerings, so the loops, matches, and branch tables they
  reconstruct re-lower byte-for-byte.
- `nop` and `drop`.
- Constants, each pinned to its declared width (an `i64.const` stays an
  `i64.const`, not a re-defaulted `i32.const`). A width pinned through an
  int-to-float conversion (`f32.convert_i64_s (i64.const 8)`) and through
  `i64.extend32_s` is preserved as well.
- `f32.demote_f64` over a width-flexible operand (a float method whose width
  follows a bare literal, such as `f64.sqrt`) keeps its f64 source rather than
  collapsing into an f32 method. A narrow atomic store or RMW
  (`i64.atomic.store16`, `i64.atomic.rmw16.add_u`) keeps its i64 value type,
  whose ambiguous method name (`atomic_store16` is shared with the i32 form)
  would otherwise re-default to i32.

Dead code is preserved too. Instructions after an `unreachable` (or another
terminator) have operands the surface syntax cannot type on its own, so the
decompiler pins them: a width-sensitive numeric operand is ascribed its opcode
width (`(_ as i64) + _`) instead of re-defaulting to `i32`, a width-changing
conversion keeps its source width with a typed hole (`(_ as i64) as i32`
re-emits a dead `wrap`, `(_ as i32) as i64_s` a dead `extend`), and a reference
conversion whose `as` surface erases its source hierarchy pins the hole with the
opcode's source type (`ref.i31` as `(_ as i32) as &i31`, `i31.get` as
`(_ as &?i31) as i32_s`, `extern.convert_any` as `(_ as &?any) as &?extern`).
`ref.test`, `ref.i31`, `i31.get`, `extern.convert_any` and `any.convert_extern`
are operations, kept and round-tripped, not dropped like a `ref.cast`. A `ref.eq`
on the polymorphic bottom pins one operand with `(_ as &?eq)`, and a `ref.is_null`
on the bottom, or on an unannotated `select` of holes, pins its operand with
`(_ as &?any)` so it does not re-parse as `i32.eqz`. A value left on the stack
past a branch, conditional or not, keeps its width the same way; a present arm of
an unannotated `select` whose fellow is a dead hole is pinned so its width and a
narrow atomic store/RMW value operand keep their type. The opcodes after the
terminator keep their types across the round trip.

The one dead-code shape not preserved is a `ref.is_null` deep in unreachable code
whose bare `!` reconnects to a dead value below interposed statements: that value
may be numeric (so `!` reads as `i32.eqz`) or a genuine non-`any` bottom
reference, and the two cannot be told apart without type information, so it is
left as written. It is value-inert (unreachable code).

## Divergences

Each of the following is a normalisation, not a change in behaviour.

1. **Locals and names.** Local order and numbering are not preserved; every use
   is rewritten consistently. The `name` section is rewritten. The type section
   may be deduplicated and renumbered.

2. **`eq` then `eqz` fuses to `ne`.** A `t.eq` followed by `i32.eqz` decompiles
   to `a != b`, which recompiles as a single `t.ne`. (`--faithful` turns this
   off; see below.)

3. **Flat cast-dispatch chains are canonicalised.** Hand-written GC code often
   takes a value apart with a flat run of `br_on_cast_fail` blocks, one
   discarded block per arm. That flat chain is recovered as a `match`, which
   re-lowers to the nested `br_on_cast` ladder rather than the flat chain, so
   the round trip is semantically faithful but not byte-for-byte. (The nested
   ladder shape itself round-trips byte-for-byte, and `--faithful` keeps the
   flat chain.)

4. **Redundant `ref.cast` erased (best-effort).** A `ref.cast` decompiles to an
   `as` ascription. While re-typing the decompiled Wax, the ascription is
   dropped whenever the operand's inferred type is already a subtype of the
   target, that is an identity cast or an upcast, so it recompiles to no
   instruction. A genuine downcast is kept and re-emits `ref.cast`. The
   decompiler also inserts scaffolding casts of its own (a member-access
   receiver, a `call_ref` callee) to nullable reference types; those are
   indistinguishable from a redundant source cast to a nullable type without
   provenance, so cast keeping is best-effort. A handful of load-bearing
   ascriptions (a width pin, a bottom-reference type name, a continuation type
   immediate) are never dropped. This drop happens only on the decompilation
   path; a cast written by hand in Wax is always kept.

5. **A typed `select` may lose its immediate.** The value type is always
   preserved through the arms, but the explicit `(result t)` immediate form is
   not guaranteed to be reproduced.

6. **Shared spellings.** A few distinct opcode streams share a single Wax
   spelling, so the recompiler picks one canonical encoding for both. These
   live in the recompiler, shared with hand-written Wax, so the decompiler
   cannot avoid them (and `--faithful` cannot either):

   - **`i64.extend32_s`** has no dedicated Wax form; it is spelled
     `(x as i32) as i64_s`, the same wrap-then-sign-extend pair a hand-written
     `i32.wrap_i64; i64.extend_i32_s` produces, and both recompile to the single
     `i64.extend32_s`.
   - **A 32-bit load widened to `i64`.** `i32.load` is spelled `m.load32(x)`,
     so `i32.load; i64.extend_i32_u` and the fused `i64.load32_u` are both
     `m.load32(x) as i64_u` and recompile to `i64.load32_u`. (The 8- and 16-bit
     narrow loads do *not* share a spelling: their pair carries an inner
     `as i32_s`, so the pair and the fused load round-trip distinctly.)
   - **The call family.** `call` and `call_indirect` desugar through `call_ref`
     (via a `ref.func` or a table access) and are recovered by pattern; a
     dead or degenerate shape that cannot re-fuse recompiles to the desugared
     `call_ref` form.
   - **Float negation of a literal.** `f32.neg`/`f64.neg` of a constant folds
     into the negated literal (Wax spells a negative float literal `-X`).

## Faithful round-tripping

The `--faithful` flag (wax output only) turns off the two stream-reshaping
recoveries it can turn off cleanly, so a decompiled module recompiles with the
same reachable instruction structure. It reliably suppresses divergences 2 and
3: `eq` then `eqz` stays `!(a == b)` (re-lowering to the `eq; eqz` pair, not
fused to `t.ne`), and a flat `br_on_cast_fail` chain is kept as separate blocks
(not recovered to a `br_on_cast` ladder). For divergence 4 it keeps a redundant
*non-null* `ref.cast` as an `as` ascription (re-emitting it), a best-effort
improvement. The Wax is pin-noisier (a kept ascription emits no instruction) but
structurally exact.

What remains under `--faithful` is only the inert normalisations it does not
gate: locals and names (divergence 1), a typed `select`'s immediate
(divergence 5), the best-effort scaffolding casts (divergence 4), and the shared
spellings (divergence 6). Width pinning is no longer faithful-only: constant
widths, leftover widths, dead-code widths, and the convert / `extend32_s`
sources are pinned on the default path too, so `--faithful` does not make width
fidelity any better than the default decompile; it only preserves the opcode
*structure* the two reshaping recoveries would otherwise change.

## How this is checked

These guarantees are enforced by a differential fuzzing harness that compares
per-opcode histograms across a round trip, over both a curated corpus and a
`wasm-smith` campaign. The `WIDTHDRIFT` leg checks that the width-sensitive
families (div/rem/shift, float truncations, ordered comparisons, `eq`/`ne`, and
the int-to-float conversions) keep full width on the default round trip; the
`FAITHDRIFT` leg checks that a `--faithful` decompile+recompile reproduces the
whole reachable opcode sequence, modulo the shared spellings and the
compiler-cast family normalised away.
