The unary integer instruction methods (clz, ctz, popcnt, extend8_s, extend16_s)
apply to a LargeInt literal (an integer beyond i32, which defaults to i64) the
same way they do to a Number/Int (which default to i32). This lets a decompiled
i64.ctz/clz/popcnt/extend whose operand stayed an abstract LargeInt round-trip;
it previously failed with "this operation cannot be applied to a value of type
int". Regression: found by the smith fuzzer.

  $ cat > f.wax <<'WAX'
  > fn a() -> i64 { (4294967296).clz(); }
  > fn b() -> i64 { (4294967296).ctz(); }
  > fn c() -> i64 { (4294967296).popcnt(); }
  > fn d() -> i64 { (4294967296).extend8_s(); }
  > fn e() -> i64 { (4294967296).extend16_s(); }
  > WAX
  $ wax -i wax -f wasm f.wax -o /dev/null --validate
