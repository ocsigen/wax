(module
  (type $ft (func (param i32) (result i32)))
  (type $ct (cont $ft))
  (tag $yield (param i32) (result i32))
  (func $handle (param $k0 (ref null $ct)) (result i32)
    (block $h (result i32)
      (resume $ct (on $yield $h) (i32.const 1) (local.get $k0))
      (return))
    (return)))
