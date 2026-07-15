(module
  (type $ft0 (sub (func (param i32) (result i32))))
  (type $k0 (sub (cont $ft0)))
  (type $ft1 (sub final $ft0 (func (param i32) (result i32))))
  (type $k1 (sub final $k0 (cont $ft1)))
  (func $up (param $c (ref $k1)) (param $x i32) (result i32)
    (resume $k0 (local.get $x) (local.get $c)))
  (func $own (param $c (ref $k1)) (param $x i32) (result i32)
    (resume $k1 (local.get $x) (local.get $c))))
