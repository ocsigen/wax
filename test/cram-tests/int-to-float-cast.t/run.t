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

The only numeric-to-i32 signed cast is a float truncation (i32.trunc_f*_s), so a
flexible `number` source — a literal like `5`, which can be a float — is taken as
one (defaulting to f64), not rejected:

  $ printf 'fn f() -> i32 {\n    5 as i32_s;\n}\n' > ok.wax
  $ wax -i wax -f wat ok.wax
  (func $f (result i32) (i32.trunc_sat_f64_s (f64.const 5)))

A *committed* integer source (here `5 & 5`, an int-only operator) has no
integer-to-i32 signed conversion, so it is still rejected:

  $ printf 'fn f() -> i32 {\n    (5 & 5) as i32_s;\n}\n' > bad.wax
  $ wax -i wax -f wasm bad.wax -o /dev/null
  Error: This value of type int cannot be cast to the target type.
   ──➤  bad.wax:2:5
  1 │ fn f() -> i32 {
  2 │     (5 & 5) as i32_s;
    ·     ^^^^^^^^^^^^^^^^
  3 │ }
  4 │ 
  [128]

A LargeInt source under a signed cast to i64 (or i32) is, like a `number`, taken
as a float: the only numeric->iNN signed conversion is a float truncation
(iNN.trunc_f*_s) — there is no i64->i64 or i64->i32 signed *integer* conversion —
so the source defaults to f64 and the cast lowers to a truncation. This lets a
decompiled iNN.trunc_f* (f*.const <big>), whose const renders as a large integer
literal, round-trip. Regression: found by the WAT-mutation fuzzer.

  $ printf 'fn f() -> i64 {\n    4294967296 as i64_s;\n}\n' > bigi64.wax
  $ wax -i wax -f wat bigi64.wax
  (func $f (result i64) (i64.trunc_sat_f64_s (f64.const 4294967296)))

So the truncation of an out-of-range float const round-trips: it decompiles to
`<big> as iNN_*_strict` (the const rendered as a large integer literal) and that
must recompile. Regression: a ROUNDTRIP failure found by the WAT-mutation fuzzer.

  $ printf '(module (func (result i32) (i32.trunc_f64_u (f64.const -4294967296))))\n' > rt.wat
  $ wax -i wat -f wax rt.wat -o rt.wax && wax -i wax -f wasm rt.wax -o /dev/null && echo ok
  ok
