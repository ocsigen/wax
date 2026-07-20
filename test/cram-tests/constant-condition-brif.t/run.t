A constant `br_if` condition is flagged by `constant-condition`, matching the
Wasm validator. When the `br_if` carries a value its operand is a sequence
`(value…, cond)`, so the condition is the last element — the lint looks there,
not at the whole operand.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the group:

  $ wax check -W correctness=warning brif.wax
  Warning [constant-condition]: This condition is always true.
   ──➤  brif.wax:4:26
  2 │ fn f() -> i32 {
  3 │     'l: do {
  4 │         _ = br_if 'l (5, 1);
    ·                          ^
  5 │         5;
  6 │     }
