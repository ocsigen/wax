Two cast-lattice cells that used to be rejected inconsistently with their
accepted neighbours (fuzz/cast-lattice.sh could not see them: a clean rejection
always passes its oracle, and neither the [null] source nor the [&extern] chain
target were enumerated).

[null as i64_s]: [null] is a valid [&?i31], and a concrete any-hierarchy
reference is accepted to [i64] ([i31.get] + extend, trapping at runtime), so
the null literal is too — like the already-accepted [null as i32_s].

  $ cat > n.wax <<'WAX'
  > fn f() -> i64 { null as i64_s; }
  > fn g() -> i64 { null as i64_u; }
  > WAX

  $ wax n.wax -f wat
  (func $f (result i64)
    (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (ref.null any))))
  )
  (func $g (result i64)
    (i64.extend_i32_u (i31.get_u (ref.cast (ref i31) (ref.null any))))
  )

[i64 as &extern]: both composants were already accepted — [i64 as &i31]
(wrap + ref.i31) and [i32 as &extern] (ref.i31 + extern.convert_any) — so the
composition is too. Same for an i64-sized literal, which wraps exactly like
[LargeInt as &i31].

  $ cat > e.wax <<'WAX'
  > fn f(p: i64) -> &extern { p as &extern; }
  > fn g() -> &extern { 18446744073709551615 as &extern; }
  > WAX

  $ wax e.wax -f wat
  (func $f (param $p i64) (result (ref extern))
    (extern.convert_any (ref.i31 (i32.wrap_i64 (local.get $p))))
  )
  (func $g (result (ref extern))
    (extern.convert_any
      (ref.i31 (i32.wrap_i64 (i64.const 18446744073709551615))))
  )

Both compile to valid wasm and round-trip (the decompiler renders the extern
composition as the two-step chain, which recompiles):

  $ wax n.wax -f wasm -o n.wasm --validate
  $ wax e.wax -f wasm -o e.wasm --validate
  $ wax -i wasm -f wax e.wasm
  type t = fn(i64) -> &extern;
  type t_2 = fn() -> &extern;
  fn f(p: i64) -> &extern {
      p as &i31 as &extern;
  }
  fn g() -> &extern {
      -1 as i64 as &i31 as &extern;
  }
  $ wax -i wasm -f wax e.wasm -o e2.wax && wax e2.wax -f wasm -o /dev/null --validate
