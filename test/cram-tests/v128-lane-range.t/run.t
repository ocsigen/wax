A v128 const lane must fit its lane width (the signed-or-unsigned range, so an
i8 lane is -128..255) and a lane immediate must be in range. An out-of-range
literal is rejected with a diagnostic rather than crashing the binary encoder
(int_of_string) or a Uint64 assertion. Regression: found by the AST-mutation
fuzzer grafting edge-value literals into v128 lanes.

A lane value that overflows the lane width is rejected (here, and far beyond
OCaml's int range — what used to crash the encoder):

  $ cat > badval.wax <<'EOF'
  > fn f() -> v128 {
  >     v128::i8x16(256, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  > }
  > EOF
  $ wax -i wax -f wasm badval.wax -o /dev/null
  Error: The lane value does not fit in 8 bits.
   ──➤  badval.wax:2:17
  1 │ fn f() -> v128 {
  2 │     v128::i8x16(256, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    ·                 ^^^
  3 │ }
  4 │ 
  [128]

A lane index near u64 max is rejected, not an assertion failure:

  $ cat > badidx.wax <<'EOF'
  > fn f(x: v128) -> i64 {
  >     m.v128_store64_lane(0, x, 18446744073709551615);
  >     m.load64(0);
  > }
  > memory m: i32 [1];
  > EOF
  $ wax -i wax -f wasm badidx.wax -o /dev/null
  Error: The lane index should be less than 2.
   ──➤  badidx.wax:2:31
  1 │ fn f(x: v128) -> i64 {
  2 │     m.v128_store64_lane(0, x, 18446744073709551615);
    ·                               ^^^^^^^^^^^^^^^^^^^^
  3 │     m.load64(0);
  4 │ }
  [128]

A float literal is not a valid integer lane (it would otherwise reach the
encoder's int_of_string and crash):

  $ cat > floatlane.wax <<'EOF'
  > fn f() -> v128 {
  >     v128::i8x16(0x1.0p+4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  > }
  > EOF
  $ wax -i wax -f wasm floatlane.wax -o /dev/null
  Error: The lane value does not fit in 8 bits.
   ──➤  floatlane.wax:2:17
  1 │ fn f() -> v128 {
  2 │     v128::i8x16(0x1.0p+4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    ·                 ^^^^^^^^
  3 │ }
  4 │ 
  [128]

In-range lanes (the signed and unsigned extremes of the width) are accepted, and
a float shape accepts integer lanes:

  $ cat > ok.wax <<'EOF'
  > fn f() -> v128 {
  >     v128::i8x16(255, -128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  > }
  > fn g() -> v128 {
  >     v128::f32x4(1, 2, 3, 4);
  > }
  > EOF
  $ wax -i wax -f wasm ok.wax -o /dev/null --validate
