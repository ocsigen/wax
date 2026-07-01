Regression (differential-validation fuzzer): a smith module whose faithful
decompilation exercises two dead-code round-trip bugs at once, so it is kept as a
binary fixture rather than reduced.

First, an f32-result block reached only by flexible float literals (a fall-through
and a br_table value): simplify dropped the `=> f32` annotation because it pinned
those literals to f32, but on re-parse they re-default to f64, so `.to_bits()` on
the block yielded i64 where i32 was expected. The keep-the-annotation decision now
inspects every collected exit's natural type, not just br_if pass-throughs.

Second, a br_on_cast whose polymorphic operand made its fall-through residual type
Unknown, so `!` (which is ref.is_null on a reference) lowered to the integer
i32.eqz. br_on_cast's residual is now the bottom reference.

It must decompile and round-trip back to a binary the validator accepts:

  $ wax -i wasm m.wasm -f wax -o t.wax && wax -i wax t.wax -f wasm -o /dev/null --validate
