(module
  (type $f (func))
  (type $c (sub (struct (field $func (ref null $f)))))
(@if (= $mode "a")
(@then
  (type $d (sub $c (struct (field $func (ref null $f)) (field $g i32))))
  (func (export "get") (param $x (ref $d)) (result i32)
    (struct.get $d $g (local.get $x)))
  (func (export "make") (result (ref $d))
    (struct.new $d (ref.null $f) (i32.const 1))))
(@else
  (type $d (sub (struct (field $g i64))))
  (func (export "get") (param $x (ref $d)) (result i32)
    (i32.wrap_i64 (struct.get $d $g (local.get $x))))
  (func (export "make") (result (ref $d))
    (struct.new $d (i64.const 2)))))
)
