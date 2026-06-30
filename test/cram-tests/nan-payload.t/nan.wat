(module
  (func (export "f") (result f32) (f32.const nan:0x200000))
  (func (export "g") (result f64) (f64.const nan:0x4000000000000))
  (func (export "h") (result f32) (f32.const -nan:0x200000)))
