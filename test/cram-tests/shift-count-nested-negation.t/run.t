The shift-count-overflow lint folds a leading sign exactly as lowering does, so
it fires only when the emitted shift has a folded constant operand. A single sign
on a literal folds (`-117775691` -> `i32.const -117775691`), so `single` warns.
A doubled sign lowers to a runtime `i32.sub 0 x` (`--117775691` ->
`(i32.sub (i32.const 0) (i32.const -117775691))`), which is not a constant
operand, so `double` does not warn — matching the Wasm validator, which sees only
the folded `i32.const`. (A recursive fold here would over-fire relative to the
validator; found as a wax/wat lint-parity divergence by fuzz/mutate-wax.)

  $ wax check -W all=warning m.wax
  Warning [shift-count-overflow]:
    The shift count 18446744073591775925 is at least the operand width (32
    bits).
   ──➤  m.wax:3:7
  1 │ #[export]
  2 │ fn single(x: i32) -> i32 {
  3 │     x << -117775691;
    ·       ^^
  4 │ }
  5 │ #[export]
  Hint: Wasm masks the count modulo 32, shifting by 21 instead.

The two counts lower differently — a folded constant vs a runtime subtraction:

  $ wax -f wat m.wax | grep -o 'i32.shl.*'
  i32.shl (local.get $x) (i32.const -117775691))
  i32.shl (local.get $x) (i32.sub (i32.const 0) (i32.const -117775691)))
