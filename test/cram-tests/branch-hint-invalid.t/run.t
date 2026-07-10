Branch hints have a mandated shape (branch-hinting proposal): the payload is
exactly `"\00"` (unlikely) or `"\01"` (likely), and a hint may only prefix a
conditional branch. wax rejects anything else rather than silently dropping it.

A payload that is not `"\00"` / `"\01"` is rejected:

  $ wax check bad-payload.wat
  Error: A branch hint must be "\00" or "\01".
  
   ──➤  bad-payload.wat:1:57
  1 │ (module (func i32.const 0 (@metadata.code.branch_hint "a") if end))
    ·                                                         ^
  2 │ 
  [128]


A hint on a non-branch instruction (here `i32.const`) is rejected, not ignored
— `br_on_*` count as branches (Wasm 3.0 / GC), unlike the pre-3.0 proposal text
that named only `if`/`br_if`:

  $ wax check misplaced.wat
  Error:
    A branch hint may only prefix a conditional branch (if, br_if, or br_on_*).
   ──➤  misplaced.wat:1:15
  1 │ (module (func (@metadata.code.branch_hint "\00") i32.const 0 drop))
    ·               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

