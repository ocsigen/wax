Regression (differential-validation fuzzer, reduced): in dead code after a
`return_call`, `i64.const <n>; i64.ne` compares an out-of-i32-range constant (a
flexible `LargeInt` literal) with a polymorphic stack value (a `_` hole). The
one-abstract-operand arm of `Ne` accepted `Number | Int | Float` but not
`LargeInt`, so it rejected the pair as "int and int" — unlike the sibling `Eq`
arm, which already accepted `LargeInt`. `!=` on a large-int literal is a valid
`i64.ne`, so accept it:

  $ cat > f.wat <<'WAT'
  > (module
  >   (func $f (result i32)
  >     return_call $g
  >     i64.const -17179869185
  >     i64.ne)
  >   (func $g (result i32) i32.const 0))
  > WAT
  $ wax -i wat -f wax f.wat
  fn f() -> i32 {
      become g();
      _ != -17179869185;
  }
  fn g() -> i32 {
      0;
  }
