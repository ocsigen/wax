(module
  (func (export "trap") (result i32)
    (i32.trunc_f32_u (f32.demote_f64 (f64.const 1e300))))
  (func (export "shift") (param $x i64) (result i64)
    (i64.shl (local.get $x) (i64.const 18446744073709551615))))
