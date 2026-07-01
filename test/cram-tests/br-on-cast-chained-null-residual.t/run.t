Regression (smith fuzzer, smith-13300). A chained `br_on_cast_fail 'l &t_19
br_on_cast 'l &?t_14 null` in dead code, where both casts branch to the same
block `'l` (originally `(result anyref)`) and the inner operand is a bare `null`.
`to_wasm` emits the outer cast's source as `lub(operand, target)` and wasm
derives its branch residual as `diff(lub, target)` — here `(ref eq)`, the
supertype of the array (t_14) and struct (t_19) types. Typing, though, derived
that residual from the operand's own type, delivering only `(ref t_14)` to the
label's join, so the block was inferred `(ref null t_14)` — too narrow to accept
the `(ref eq)` the emitted instruction actually delivers. `wax check` accepted the
module but the re-emitted wasm failed validation. The residual is now typed from
the same `lub` source `to_wasm` uses, so the block widens to `(ref null eq)` and
it round-trips:

  $ wax -i wasm m.wasm -f wax -o t.wax && wax -i wax t.wax -f wasm -o /dev/null --validate -W unused=hidden
