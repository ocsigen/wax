In dead code (after `unreachable`) a reference-family OPERATION pops holes off the
polymorphic stack. Unlike a `ref.cast` (a compiler-inserted type pin the
decompiler cannot always distinguish from a source cast), these compute a value
and must survive a Wasm->Wax->Wasm round trip. Each has a plain `as` surface that
erases its operand's source hierarchy, so `From_wasm` pins the hole with the
opcode's source type — otherwise a bare `_ as &i31` / `_ as i32_s` re-types the
hole to the target and drops the op: `ref.i31` (source `i32`) becomes
`(_ as i32) as &i31`, `i31.get_s/u` (source `&?i31`) becomes
`(_ as &?i31) as i32_s`, `extern.convert_any` (source `&?any`) becomes
`(_ as &?any) as &?extern`, and `any.convert_extern` (source `&?extern`) becomes
`(_ as &?extern) as &?any`.

The two cross-hierarchy converts also arise from a null (`ref.null any` /
`ref.null extern`); the inner any/extern cast is kept (it would otherwise collapse
to `null as &?extern` = `ref.null extern`, dropping the convert). And two ops that
share a numeric Wax surface with a polymorphic `select` of holes are pinned so
the select does not re-default to the numeric form: `ref.is_null` (the `!` surface,
else an `i32.eqz`) with `(_?_:_) as &?any`, and an `f32.const` select arm (the `?:`
carries no result type) with `as f32`.

  $ cat > m.wat <<'WAT'
  > (module
  >   (func $ref_i31 unreachable ref.i31 drop)
  >   (func $i31_get_s unreachable i31.get_s drop)
  >   (func $extern_of_any unreachable extern.convert_any drop)
  >   (func $any_of_extern unreachable any.convert_extern drop)
  >   (func $extern_of_null unreachable ref.null any extern.convert_any drop)
  >   (func $any_of_null unreachable ref.null extern any.convert_extern drop)
  >   (func $isnull_sel (result i32) unreachable i32.const 1 select ref.is_null)
  >   (func $const_sel unreachable f32.const 0x0p+0 i32.const 0 select unreachable))
  > WAT
  $ wax -i wat -f wax --faithful m.wat
  fn ref_i31() {
      unreachable;
      _ = _ as i32 as &i31;
  }
  fn i31_get_s() {
      unreachable;
      _ = _ as &?i31 as i32_s;
  }
  fn extern_of_any() {
      unreachable;
      _ = _ as &?any as &?extern;
  }
  fn any_of_extern() {
      unreachable;
      _ = _ as &?extern as &?any;
  }
  fn extern_of_null() {
      unreachable;
      _ = null as &?any as &?extern;
  }
  fn any_of_null() {
      unreachable;
      _ = null as &?extern as &?any;
  }
  fn isnull_sel() -> i32 {
      unreachable;
      !((1?_:_) as &?any);
  }
  fn const_sel() {
      unreachable;
      0?_:0x0p+0 as f32;
      unreachable;
  }

Round-tripping back to Wasm recovers every operation (and the select arm's width):

  $ wax -i wat -f wax --faithful m.wat -o m.wax && wax -i wax -f wat m.wax
  (func $ref_i31 (unreachable) (drop (ref.i31)))
  (func $i31_get_s (unreachable) (drop (i31.get_s)))
  (func $extern_of_any (unreachable) (drop (extern.convert_any)))
  (func $any_of_extern (unreachable) (drop (any.convert_extern)))
  (func $extern_of_null
    (unreachable)
    (drop (extern.convert_any (ref.null any)))
  )
  (func $any_of_null
    (unreachable)
    (drop (any.convert_extern (ref.null extern)))
  )
  (func $isnull_sel (result i32)
    (unreachable)
    (ref.is_null (select (i32.const 1)))
  )
  (func $const_sel
    (unreachable)
    (select (f32.const 0x0p+0) (i32.const 0))
    (unreachable)
  )
