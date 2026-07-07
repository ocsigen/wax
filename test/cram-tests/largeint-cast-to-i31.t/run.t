ref.i31 takes an i32. When decompiling [i64.const N; i32.wrap_i64; ref.i31] for
an i64-sized literal N, simplify fuses the [as i32] wrap into the [as &i31] cast
(to_wasm re-emits both: i32.wrap_i64 then ref.i31). The residue [N as &i31] with
N too big for i32 (a large-int literal) must therefore type-check as that wrap;
it previously failed with "This value of type int cannot be cast to the target
type". Regression: found by the differential-validation fuzzer.

  $ cat > m.wat <<'WAT'
  > (module (func (export "g") (result (ref i31))
  >   i64.const 6945585311769240651
  >   i32.wrap_i64
  >   ref.i31))
  > WAT

  $ wax -i wat -f wax m.wat
  #[export]
  fn g() -> &i31 {
      6945585311769240651 as &i31;
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o /dev/null --validate
