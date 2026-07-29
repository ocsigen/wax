(module
  (memory 1)
  (func $dummy)

  ;; --- Each function below wraps a width-sensitive i64/f32 tree in one "width
  ;; eraser": a consumer whose Wax surface carries a different width, or none.

  ;; drop: the value's width lives in the anonymous let's annotation
  (func (export "drop_")
    (drop (i64.div_u (i64.const 1) (i64.add (i64.const 2147483648) (i64.const 2147483648)))))
  ;; comparison: yields i32 whatever the operands' width
  (func (export "cmp") (result i32)
    (i64.eq (i64.shr_u (i64.const 4096) (i64.const 40)) (i64.const 0)))
  ;; eqz: i64 operand, i32 result
  (func (export "eqz") (result i32)
    (i64.eqz (i64.shr_u (i64.const 4096) (i64.const 40))))
  ;; wrap: the surface `as i32` carries the result width, not the source's
  (func (export "wrap") (result i32)
    (i32.wrap_i64 (i64.shl (i64.const 1) (i64.const 40))))
  ;; a truncation's source float width
  (func (export "trunc_src") (result i64) (i64.trunc_f32_u (f32.const 1.5)))
  ;; a conversion's source integer width
  (func (export "convert_src") (result f32) (f32.convert_i64_s (i64.const 8)))
  ;; a narrow i64 store: the method name carries only the access width
  (func (export "narrow_store")
    (i64.store8 (i32.const 0) (i64.shr_u (i64.const 4096) (i64.const 40))))
  ;; a select arm (the `?:` surface carries no result type)
  (func (export "select_arm") (param i32) (result i32)
    (i32.wrap_i64 (select (i64.shr_u (i64.const 4096) (i64.const 40)) (i64.const 1) (local.get 0))))
  ;; a method-form op whose width is baked into the receiver
  (func (export "rotl") (result i32)
    (i64.eqz (i64.rotl (i64.const 4096) (i64.const 40))))
  (func (export "f32_method") (result i32)
    (i32.trunc_f32_u (f32.sqrt (f32.const 2))))
  ;; a value an unconditional branch leaves stranded
  (func (export "br_leftover") (result i32)
    (i64.shr_u (i64.const 4096) (i64.const 40))
    (br 0 (i32.const 1)))
  ;; a value stranded past a CONDITIONAL branch (no consumer, no push_poly)
  (func (export "br_if_stranded") (param i32) (result i32)
    (block (result i64) (f64.trunc (f64.const 1.5)) (drop) (i64.shr_u (i64.const 4096) (i64.const 40))
           (br_if 0 (local.get 0)) (drop) (i64.const 0))
    (drop) (i32.const 0))
  ;; a block result annotation as the pin: the two f32 blocks feed a comparison
  (func (export "block_result_pin") (result i32)
    (f32.gt (block (result f32) (call $dummy) (f32.const 3))
            (block (result f32) (call $dummy) (f32.const 3))))

  ;; a receiver whose pop an interposed zero-value statement blocks, so the method
  ;; reads a HOLE and the value below is stranded: the downstream demote then
  ;; re-grounds the whole chain unless the receiver's own type is stated
  (func (export "blocked_receiver") (result f32)
    f64.const 0x1p-1063
    (block)
    f64.floor
    f32.demote_f64)

  ;; --- Dead code: every operand is a hole on a polymorphic stack.
  (func (export "dead") (result i32)
    unreachable
    (drop (i64.div_u (i64.const 1) (i64.const 0)))
    i64.shr_u drop
    select i64.rem_u drop
    i64.clz drop
    f32.sqrt drop
    (i32.const 0))
)
