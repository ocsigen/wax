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

3. **Cast fusion.** Chains of `extend`, `wrap`, and `reinterpret` may fold. For
   example a `wrap` of an `extend` back to the same width cancels.

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

## How this is checked

These guarantees are enforced by a differential fuzzing harness that compares
per-opcode histograms across a round trip, over both a curated corpus and a
`wasm-smith` campaign.
