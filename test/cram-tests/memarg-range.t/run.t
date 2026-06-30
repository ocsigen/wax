A memory offset or alignment immediate must fit a 64-bit unsigned integer; a
literal beyond u64 is rejected with a diagnostic rather than crashing the
converter's Uint64.of_string. Regression: found by the AST-mutation fuzzer
grafting an edge-value literal into a memarg.

  $ cat > bad.wax <<'EOF'
  > fn f(p: i32) -> i32 {
  >     m.load32(p, 18446744073709551616, 4);
  > }
  > memory m: i32 [1];
  > EOF
  $ wax -i wax -f wasm bad.wax -o /dev/null
  Error: This memory offset or alignment must fit a 64-bit unsigned integer.
   ──➤  bad.wax:2:17
  1 │ fn f(p: i32) -> i32 {
  2 │     m.load32(p, 18446744073709551616, 4);
    ·                 ^^^^^^^^^^^^^^^^^^^^
  3 │ }
  4 │ memory m: i32 [1];
  [128]

A large-but-in-u64 offset (the third arg; the second is alignment) is fine on an
i64 memory:

  $ cat > ok.wax <<'EOF'
  > fn f(p: i64) -> i32 {
  >     m.load32(p, 4, 9223372036854775807);
  > }
  > memory m: i64 [1];
  > EOF
  $ wax -i wax -f wasm ok.wax -o /dev/null --validate
