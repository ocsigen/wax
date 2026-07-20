A `br_on_cast` (or `br_on_cast_fail`, and the descriptor variants) to an unbound
label made `type_branch` compute the fall-through result as `Array.sub params 0
(len - 1)` where `params` — recovered from the unbound label — is empty, so
`len - 1` is `-1` and `Array.sub` raised, crashing the type checker with an
uncaught exception. It now clamps the length with `max 0`, so the unbound-label
error is reported instead. Regression: the nightly mutate-wax campaign.

  $ cat > bad.wax <<'WAX'
  > type t0 = open { };
  > fn f(x: &?struct) {
  >     _ = do {
  >         br_on_cast 'nope &t0 x;
  >     };
  > }
  > WAX
  $ wax check bad.wax
  Error: The label 'nope' is not bound.
   ──➤  bad.wax:4:20
  2 │ fn f(x: &?struct) {
  3 │     _ = do {
  4 │         br_on_cast 'nope &t0 x;
    ·                    ^^^^^
  5 │     };
  6 │ }
  [128]
