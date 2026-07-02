A branch instruction whose target's arity does not match must be rejected with a
clean diagnostic, never crash the type checker. Two arity-guard regressions in
`type_branch` (both found by fuzz/mutate-wax.sh):

`br_on_non_null` to a target block with no result type used to raise
`Invalid_argument("Array.sub")` — the fall-through was computed as
`Array.sub params 0 (len - 1)`, i.e. `Array.sub _ 0 (-1)` when the target had
zero params. It is now a clean rejection:

  $ cat > nonnull.wax <<'WAX'
  > fn f(p: &?any) {
  >     'l: {
  >         br_on_non_null 'l p;
  >     }
  > }
  > WAX
  $ wax check nonnull.wax
  Error: This instruction provides 1 value(s) but 0 was/were expected.
   ──➤  nonnull.wax:3:27
  1 │ fn f(p: &?any) {
  2 │     'l: {
  3 │         br_on_non_null 'l p;
    ·                           ^
  4 │     }
  5 │ }
  [128]
