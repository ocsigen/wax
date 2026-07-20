A float literal that rounds to a valid f32 stays width-flexible and folds into an
`f32.const`; one that overflows f32 gets type f64, so `as f32` lowers to a real
`f32.demote_f64` instead of an out-of-range `f32.const` (which would be invalid
WAT). The demote sits at the top of the operand, so `(1e300).floor()` stays an
f64 floor — not a semantics-changing `f32.floor`.

  $ wax -i wax -f wat range.wax
  (func $in_range (export "in_range") (result f32) (f32.const 1.5))
  
  (func $overflow (export "overflow") (result f32)
    (f32.demote_f64 (f64.const 1e300))
  )
  
  (func $floor_overflow (export "floor_overflow") (result f32)
    (f32.demote_f64 (f64.floor (f64.const 1e300)))
  )



A bare out-of-range f32 binding is a clean type error, not silent invalid output:

  $ wax check bind.wax
  Error: This instruction has type 'f64' but is expected to have type 'f32'.
   ──➤  bind.wax:2:30
  1 │ #[export = "g"]
  2 │ fn g() -> f32 { let x: f32 = 1e300; x; }
    ·                              ^^^^^
  3 │ 
  [128]
