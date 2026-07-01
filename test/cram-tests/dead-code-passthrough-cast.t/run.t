Regression (differential-validation fuzzer, reduced): unreachable code after a
tail call (`become`) contains `br_if 'l_3 (_, …) as i32` — a value passed through
a branch to an inferred block, then cast. The block's result is i64 (used via
`^ g_4`), so the cast is a real `i32.wrap_i64`. But `join_value_types` returned
the block result without *pinning* the polymorphic (`Unknown`) pass-through to it,
so on re-parse the value stayed `Unknown`, `To_wasm` dropped the wrap as a no-op,
and the i64 was fed to an i32 load — wax rejected its own emitted binary. The join
now pins an `Unknown` exit to the block result, so the cast survives and it
round-trips:

  $ wax -i wax m.wax -f wasm -o /dev/null --validate
