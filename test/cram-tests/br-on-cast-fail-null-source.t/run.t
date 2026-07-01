Regression (smith fuzzer, smith-6864/smith-17323): a module whose decompilation
feeds a bare `null` operand to `br_on_cast_fail 'l &?i31 null` (a `ref.null any`
in dead code whose annotation was dropped). The null-operand arm typed the branch
residual as the any-hierarchy bottom `(ref none)` — reasoning that a null always
matches the nullable target and falls through, so the branch is dead. But
`to_wasm` reconstructs the source as the cast target made nullable and emits
`br_on_cast_fail (ref null i31) (ref null i31)`, whose residual wasm derives from
those immediates as `diff = (ref i31)` — not `(ref none)`. No valid source can
yield a bottom residual (the source must be a supertype of the target), so the
typer's residual was more precise than any emittable wasm. When simplification
narrowed the target block to a bottom `(ref null none)`, the emitted `(ref i31)`
residual then failed the module's own validation. The residual is now typed as
`diff(source, ty)`, mirroring wasm validation, so it round-trips:

  $ wax -i wasm m.wasm -f wax -o t.wax && wax -i wax t.wax -f wasm -o /dev/null --validate -W unused=hidden
