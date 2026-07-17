A `select` yields the type of its arms, so when both arms are width-flexible
literal trees the decompiled `?:` must carry their combined width tag (as
`int_bin_op` does). Otherwise a downstream width eraser -- here `i32.wrap_i64` --
cannot pin the arms, they re-default to i32 on the round trip, and the wrap
vanishes.

  $ cat > sel.wat <<'WAT'
  > (module (func (result i32)
  >   (i32.wrap_i64 (select (i64.shr_u (i64.const 4096) (i64.const 40))
  >                         (i64.const 1) (i32.const 1)))))
  > WAT

  $ wax -i wat -f wax sel.wat
  fn f() -> i32 {
      (1?4096 >>u 40:1) as i64 as i32;
  }

The i64 select and the wrap survive the round trip (an all-i32 select would mask
the shift count and drop the wrap, yielding 16 instead of 0):

  $ wax -i wat -f wax sel.wat | wax -i wax -f wat
  (func $f (result i32)
    (i32.wrap_i64
      (select (i64.shr_u (i64.const 4096) (i64.const 40)) (i64.const 1)
        (i32.const 1)))
  )
