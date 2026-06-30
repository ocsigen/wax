An integer literal whose magnitude does not fit u64 cannot be any integer type,
so it is float-only: using it where an integer is expected is a clean type error
rather than an Int64.of_string crash in the binary encoder, while a float context
accepts it. (u64 max itself still fits i64.) Regression: found alongside the
AST-mutation fuzzer's edge-value literals.

  $ cat > big.wax <<'EOF'
  > fn f() -> i64 {
  >     18446744073709551616;
  > }
  > EOF
  $ wax check big.wax
  Error: Expecting type i64 but got type float.
   ──➤  big.wax:2:5
  1 │ fn f() -> i64 {
  2 │     18446744073709551616;
    ·     ^^^^^^^^^^^^^^^^^^^^
  3 │ }
  4 │ 
  [123]

  $ cat > okf.wax <<'EOF'
  > fn f() -> f64 {
  >     18446744073709551616;
  > }
  > EOF
  $ wax -i wax -f wat okf.wax --validate | grep const
  (func $f (result f64) (f64.const 18446744073709551616))

u64 max still fits i64:

  $ cat > u64.wax <<'EOF'
  > fn f() -> i64 {
  >     18446744073709551615;
  > }
  > EOF
  $ wax -i wax -f wat u64.wax --validate | grep const
  (func $f (result i64) (i64.const 18446744073709551615))
