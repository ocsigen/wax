(module
  (memory 1)
  (func (export "simd") (param $a v128) (param $b v128)
    ;; v128 memory ops exercise Scan's memarg (align+offset LEB) decoding
    i32.const 0 v128.load drop
    i32.const 0 v128.load align=1 drop
    i32.const 0 v128.load offset=16 align=8 drop
    i32.const 0 v128.load8x8_s offset=1 drop
    i32.const 0 v128.load16x4_u drop
    i32.const 0 v128.load32_zero offset=4 drop
    i32.const 0 v128.load64_splat drop
    i32.const 0 local.get $a v128.load8_lane offset=2 3
    i32.const 0 local.get $a v128.load32_lane 1 drop
    i32.const 0 local.get $a v128.store drop
    i32.const 0 local.get $a v128.store16_lane offset=1 5
    ;; immediates: 16-byte const, 16-lane shuffle, single lane idx
    v128.const i32x4 1 2 3 4 drop
    local.get $a local.get $b i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 drop
    local.get $a i32x4.extract_lane 2 drop
    local.get $a i32.const 5 i32x4.replace_lane 1 drop
    i32.const 7 i32x4.splat drop
    local.get $a local.get $b i32x4.add drop
    local.get $a i8x16.abs drop
  )
)
