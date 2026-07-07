A strict signed cast (`as iN_s_strict` / `as iN_u_strict`) is a float-to-int
trunc, so its operand must be a float. A bare float literal carries the abstract
`float` type; it must still be accepted (defaulting to f64), so the
`iN.trunc_fM_s` a decompiled `fM.const` produces round-trips instead of being
rejected as "float cannot be cast". (Regression: smith-found round-trip failure.)

  $ wax -i wasm -f wax trunc.wasm
  type t = fn() -> i64;
  type t_2 = fn() -> i32;
  #[export]
  fn s() -> i64 {
      0x1.8p+0 as i64_s_strict;
  }
  #[export]
  fn u() -> i32 {
      0x1.4p+1 as i32_u_strict;
  }
  #[export]
  fn ext() -> i64 {
      0x1.cp+1 as i64_s_strict as i32 as i64_s;
  }

The decompiled Wax recompiles to a valid module.

  $ wax -i wasm -f wax trunc.wasm -o trunc.wax
  $ wax -i wax -f wasm trunc.wax -o out.wasm --validate
  $ wax -i wasm -f wat out.wasm --validate | grep -c trunc
  3

A strict cast still requires a float operand: an integer source is rejected.

  $ printf 'fn f(x: i64) -> i32 {\n    x as i32_s_strict;\n}\n' > bad.wax
  $ wax -i wax -f wasm bad.wax -o /dev/null --validate
  Error: This value of type i64 cannot be cast to the target type.
   ──➤  bad.wax:2:5
  1 │ fn f(x: i64) -> i32 {
  2 │     x as i32_s_strict;
    ·     ^^^^^^^^^^^^^^^^^
  3 │ }
  4 │ 
  [128]
