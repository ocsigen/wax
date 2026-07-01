A SIMD lane immediate must be a constant integer in range. The range check read
the literal with [int_literal], which returns [None] for a value too large even
for [u64]; the [let>@] then silently skipped the check and the oversized literal
reached [to_wasm]'s [int_of_string], crashing. A constant [Int] out of lane range
-- including one beyond [u64] -- is now a clean error (the same guard covers the
memory lane-index ops in [type_simd_mem_method_call]). Regression: found by the
AST-mutation fuzzer.

  $ echo 'fn f(v: v128) -> i32 { v.extract_lane_i32x4(18446744073709551616); }' > a.wax
  $ wax check a.wax
  Error: The lane index should be less than 4.
   ──➤  a.wax:1:45
  1 │ fn f(v: v128) -> i32 { v.extract_lane_i32x4(18446744073709551616); }
    ·                                             ^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

A valid lane index still compiles.

  $ echo '#[export="g"] fn g(v: v128) -> i32 { v.extract_lane_i32x4(3); }' > ok.wax
  $ wax check ok.wax
