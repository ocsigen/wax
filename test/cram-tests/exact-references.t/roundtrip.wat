(module
  (type $s (struct (field i32)))
  (func (export "cast") (param $x (ref null $s)) (result (ref (exact $s)))
    (ref.cast (ref (exact $s)) (local.get $x)))
  (global (ref null (exact $s)) (ref.null (exact $s))))
