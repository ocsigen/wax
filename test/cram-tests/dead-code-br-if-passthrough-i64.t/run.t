Regression (differential-validation fuzzer): a smith module kept as a binary
fixture — the failing block only misbehaves because a module-level chain of holes
concretises the br_if pass-through, which does not survive hand reduction.

An inferred block has two exits: an i64 fall-through (a large-int literal) and a
dead-code `br_if` whose pass-through value is polymorphic. Simplify dropped the
block's `=> i64` result annotation because the pass-through's exact exit type was
snapshotted as `Unknown` (at the br_if, before its own downstream arithmetic types
it) and an `Unknown` exact was treated as imposing no width constraint. But with
the annotation gone, that pass-through re-defaults to i32 on re-parse, so the join
with the i64 fall-through fails ("no common supertype"). A polymorphic exact now
re-defaults to i32 (the dead-code default), so the load-bearing annotation is kept
and it round-trips:

  $ wax -i wasm m.wasm -f wax -o t.wax && wax -i wax t.wax -f wasm -o /dev/null --validate -W unused=hidden
