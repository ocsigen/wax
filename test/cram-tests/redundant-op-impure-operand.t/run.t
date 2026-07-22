The validator's `redundant-operation` lint tracks operands on a small stack that
an impure producer (a call, a trapping op) clears. A *no-effect identity* — here
`x >> 0` — is redundant whatever the other operand is (its traps and effects are
preserved), so the constant on top of the stack is enough to report it even when
the other operand is not tracked. This matches the Wax linter, which reports it
structurally (keeping the two sides in parity).

  $ wax check -W redundant-operation=warning shift.wat
  Warning [redundant-operation]: This operation has no effect on its result.
   ──➤  shift.wat:4:6
  2 │   (func $g (result i32) (i32.const 1))
  3 │   (func (export "f") (result i32)
  4 │     (i32.shr_s (call $g) (i32.const 0))))
    ·      ^^^^^^^^^
  5 │ 
