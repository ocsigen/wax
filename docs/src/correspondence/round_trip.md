# Round-Tripping

Decompiling a Wasm module to Wax and recompiling it (`wasm → wax → wasm`)
reproduces the instruction stream opcode-for-opcode, dead code included. The
type section is preserved as well: structurally identical types stay distinct
and keep their order and numbering. The rest of this page lists the places where
the round trip diverges. Every divergence is semantically inert: the recompiled
module behaves identically, it just is not byte-for-byte identical.

## Divergences

1. **Locals and names.** Local order and numbering are not preserved; every use
   is rewritten consistently. The `name` section is rewritten.

2. **`eq` then `eqz` fuses to `ne`.** A `t.eq` followed by `i32.eqz` decompiles
   to `a != b`, which recompiles as a single `t.ne`. (`--faithful` keeps the
   pair.)

3. **Flat cast-dispatch chains are canonicalised.** A flat run of
   `br_on_cast_fail` blocks is recovered as a `match`, which re-lowers to the
   nested `br_on_cast` ladder rather than the flat chain. The ladder shape
   itself round-trips byte-for-byte. (`--faithful` keeps the flat chain.)

4. **Redundant `ref.cast` erased (best-effort).** A `ref.cast` decompiles to an
   `as` ascription, which is dropped when the operand's inferred type is already
   a subtype of the target (an identity cast or an upcast), so it recompiles to
   no instruction. A genuine downcast is kept and re-emits `ref.cast`. The
   decompiler also inserts scaffolding casts of its own (a member-access
   receiver, a `call_ref` callee) to nullable reference types, and these are
   indistinguishable from a redundant source cast to a nullable type, so cast
   keeping is best-effort. A few load-bearing ascriptions (a width pin, a
   bottom-reference type name, a continuation type immediate) are never dropped.

5. **A typed `select` may lose its immediate.** The value type is always
   preserved through the arms, but the explicit `(result t)` immediate form is
   not guaranteed to be reproduced.

6. **Shared spellings.** A few distinct opcode streams share a single Wax
   spelling, so the recompiler picks one canonical encoding for both:

   - **`i64.extend32_s`** is spelled `(x as i32) as i64_s`, the same
     wrap-then-sign-extend pair a hand-written `i32.wrap_i64; i64.extend_i32_s`
     produces, and both recompile to `i64.extend32_s`.
   - **A 32-bit load widened to `i64`.** `i32.load; i64.extend_i32_u` and the
     fused `i64.load32_u` are both `m.load32(x) as i64_u` and recompile to
     `i64.load32_u`. The atomic analogue behaves the same:
     `i32.atomic.load; i64.extend_i32_u` and `i64.atomic.load32_u` are both
     `m.atomic_load32(x) as i64_u`. (The 8- and 16-bit narrow loads carry an
     inner `as i32_s`, so the pair and the fused load stay distinct; only the
     zero-extending `_u` load32 fuses.)
   - **The call family.** `call` and `call_indirect` desugar through `call_ref`
     (via a `ref.func` or a table access) and are recovered by pattern; a shape
     that cannot re-fuse recompiles to the desugared `call_ref` form.
   - **Float negation of a literal.** `f32.neg`/`f64.neg` of a constant folds
     into the negated literal (Wax spells a negative float literal `-X`), so
     both `const -X` and `const X; neg` recompile the same way.
   - **Empty `else`.** An `if` with an empty `else` branch decompiles to a
     branchless `if`, which recompiles without the `else`.

7. **Types may become more precise.** A declared type wider than the value it
   holds tightens to the value's precise type across a round trip: the
   decompiler infers each binding's type from its content and drops the wider
   annotation, and the recompiler re-infers the precise type. The module still
   validates (the precise type is a subtype of the original) and behaves
   identically. This affects a `local` or a `const` global declared at a
   supertype but only ever assigned a narrower value, a block result type
   declared wider than its body when no consumer pins the wider type, and a
   `br_on_cast`'s source-type immediate re-inferred from its operand.

## Faithful round-tripping

The `--faithful` flag (wax output only) preserves the reachable instruction
structure the reshaping recoveries would otherwise change. It keeps the
`eq; eqz` pair rather than fusing to `t.ne` (divergence 2), keeps a flat
`br_on_cast_fail` chain rather than recovering the `br_on_cast` ladder
(divergence 3), and keeps a redundant non-null `ref.cast` as an `as` ascription
(divergence 4). The other divergences are inert normalisations it does not gate.

## How this is checked

These guarantees are enforced by a differential fuzzing harness that compares
per-opcode histograms across a round trip, over both a curated corpus and a
`wasm-smith` campaign.
