A signed/unsigned cast of an integer literal to a float (f*.convert_i*) defaults
the source's width the same way the cast to i64 does (i64.extend_i*): a Number or
Int source becomes i32, a LargeInt source becomes i64. This lets a decompiled
f*.convert_i*_s/_u whose integer operand stayed abstract (e.g. produced by a
width-agnostic popcnt/ctz chain) round-trip. Regression: found by the smith fuzzer.

  $ cat > f.wax <<'WAX'
  > fn a() -> f64 { 5 as f64_s; }
  > fn b() -> f32 { 5 as f32_u; }
  > fn c() -> f64 { 4294967296 as f64_s; }
  > fn d() -> f32 { 4294967296 as f32_u; }
  > WAX
  $ wax -i wax -f wasm f.wax -o /dev/null --validate

There is no integer-to-i32 signed conversion, so a cast of an integer literal to
i32_s is still rejected:

  $ printf 'fn f() -> i32 {\n    5 as i32_s;\n}\n' > bad.wax
  $ wax -i wax -f wasm bad.wax -o /dev/null
  Error: This value of type number cannot be cast to the target type.
   ──➤  bad.wax:2:5
  1 │ fn f() -> i32 {
  2 │     5 as i32_s;
    ·     ^^^^^^^^^^
  3 │ }
  4 │ 
  [128]
