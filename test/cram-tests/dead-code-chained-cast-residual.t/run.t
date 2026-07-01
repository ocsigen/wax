Regression (differential-validation fuzzer): a smith module whose decompilation
puts a chained `br_on_cast_fail 'l &t br_on_cast 'l &?t2 _` in dead code (after a
`become`/`br_table`), so the inner cast's operand is polymorphic (`Unknown`).
`to_wasm` re-expands such a cast by recovering the source as the cast *target*, so
the inner br_on_cast's fall-through residual is `t2 \ t2` — a concrete reference,
which is exactly what feeds the outer br_on_cast_fail. Typing the fall-through as
the bottom reference (`UnknownRef` → `(ref none)`) instead made the outer cast's
first type `(ref none)`, which the validator rejected against the recovered source
(`produces (ref $t) but (ref none) expected`). The residual is now `diff(t2, t2)`,
so a chained cast recovers a matching source and it round-trips:

  $ wax -i wasm m.wasm -f wax -o t.wax && wax -i wax t.wax -f wasm -o /dev/null --validate -W unused=hidden
