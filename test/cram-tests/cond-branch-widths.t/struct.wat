(module
  (@if $p
   (@then (type $s (struct (field $f i64))))
   (@else (type $s (struct (field $f i32)))))
  (func (export "f") (param $x (ref $s)) (drop (struct.get $s $f (local.get $x)))))
