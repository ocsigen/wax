SIMD (v128) instructions convert between WAT and the wax surface syntax in both
directions. Vector ops are method intrinsics with the lane shape in the name
(a.add_i32x4(b)); constants and bitselect are free functions; loads/stores are
methods on a memory object. This pins the surface form (wat -> wax) and the
lowering back (wax -> wat); the binary is byte-identical modulo debug names.

  $ wax simd.wat -f wax -o out.wax && cat out.wax
  memory m: i32 [1];
  fn f(a: v128, b: v128) -> v128 {
      _ = v128::i32x4(1, 2, 3, 4);
      _ = v128::f32x4(1.5, 2.5, 3.5, 4.5);
      _ = v128::i8x16(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);
      _ = (5).splat_i32x4();
      _ = (1.5).splat_f64x2();
      _ = a.add_i32x4(b);
      _ = a.mul_f32x4(b);
      _ = a.min_s_i8x16(b);
      _ = a.lt_u_i16x8(b);
      _ = a.lt_f32x4(b);
      _ = a.neg_i32x4();
      _ = a.sqrt_f64x2();
      _ = a.extadd_pairwise_i8x16_u_i16x8();
      _ = a.trunc_sat_f32x4_s_i32x4();
      _ = a.convert_i32x4_s_f32x4();
      _ = a.extend_low_i8x16_s_i16x8();
      _ = a.narrow_i16x8_u_i8x16(b);
      _ = a.dot_i16x8_s_i32x4(b);
      _ = a.extmul_low_i8x16_s_i16x8(b);
      _ = a.swizzle_i8x16(b);
      _ = a.and_v128(b);
      _ = a.not_v128();
      _ = a.extract_lane_u_i8x16(3);
      _ = a.extract_lane_i32x4(1);
      _ = a.replace_lane_i32x4(1, 9);
      _ = a.shuffle_i8x16(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, b);
      _ = a.shl_i16x8(2);
      _ = a.shr_s_i32x4(1);
      _ = a.any_true_v128();
      _ = a.all_true_i32x4();
      _ = a.bitmask_i8x16();
      _ = v128::bitselect(a, b, a);
      _ = a.relaxed_madd_f32x4(b, a);
      _ = m.v128_load(0);
      _ = m.v128_load8x8_s(0);
      _ = m.v128_load32_zero(0);
      _ = m.v128_load8_splat(0);
      _ = m.v128_load8_lane(0, a, 3);
      m.v128_store(0, a);
      m.v128_store8_lane(0, a, 3);
      a;
  }

Lowering back to WAT reproduces the instructions (the wax round-trips):

  $ wax out.wax -i wax -f wat -o out.wat && cat out.wat
  (memory $m 1)
  (func $f (param $a v128) (param $b v128) (result v128)
    (drop (v128.const i32x4 1 2 3 4))
    (drop (v128.const f32x4 1.5 2.5 3.5 4.5))
    (drop (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))
    (drop (i32x4.splat (i32.const 5)))
    (drop (f64x2.splat (f64.const 1.5)))
    (drop (i32x4.add (local.get $a) (local.get $b)))
    (drop (f32x4.mul (local.get $a) (local.get $b)))
    (drop (i8x16.min_s (local.get $a) (local.get $b)))
    (drop (i16x8.lt_u (local.get $a) (local.get $b)))
    (drop (f32x4.lt (local.get $a) (local.get $b)))
    (drop (i32x4.neg (local.get $a)))
    (drop (f64x2.sqrt (local.get $a)))
    (drop (i16x8.extadd_pairwise_i8x16_u (local.get $a)))
    (drop (i32x4.trunc_sat_f32x4_s (local.get $a)))
    (drop (f32x4.convert_i32x4_s (local.get $a)))
    (drop (i16x8.extend_low_i8x16_s (local.get $a)))
    (drop (i8x16.narrow_i16x8_u (local.get $a) (local.get $b)))
    (drop (i32x4.dot_i16x8_s (local.get $a) (local.get $b)))
    (drop (i16x8.extmul_low_i8x16_s (local.get $a) (local.get $b)))
    (drop (i8x16.swizzle (local.get $a) (local.get $b)))
    (drop (v128.and (local.get $a) (local.get $b)))
    (drop (v128.not (local.get $a)))
    (drop (i8x16.extract_lane_u 3 (local.get $a)))
    (drop (i32x4.extract_lane 1 (local.get $a)))
    (drop (i32x4.replace_lane 1 (local.get $a) (i32.const 9)))
    (drop
      (i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 (local.get $a)
        (local.get $b)))
    (drop (i16x8.shl (local.get $a) (i32.const 2)))
    (drop (i32x4.shr_s (local.get $a) (i32.const 1)))
    (drop (v128.any_true (local.get $a)))
    (drop (i32x4.all_true (local.get $a)))
    (drop (i8x16.bitmask (local.get $a)))
    (drop (v128.bitselect (local.get $a) (local.get $b) (local.get $a)))
    (drop (f32x4.relaxed_madd (local.get $a) (local.get $b) (local.get $a)))
    (drop (v128.load $m (i32.const 0)))
    (drop (v128.load8x8_s $m (i32.const 0)))
    (drop (v128.load32_zero $m (i32.const 0)))
    (drop (v128.load8_splat $m (i32.const 0)))
    (drop (v128.load8_lane $m 3 (i32.const 0) (local.get $a)))
    (v128.store $m (i32.const 0) (local.get $a))
    (v128.store8_lane $m 3 (i32.const 0) (local.get $a))
    (local.get $a)
  )

A v128.const global initializer is a constant expression:

  $ wax global.wat -f wax -o g.wax && cat g.wax
  let g = v128::i32x4(0, 1, 2, 3);
