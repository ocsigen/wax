(module
  (@if $p
   (@then (type $ft (func (result i64))))
   (@else (type $ft (func (result i32)))))
  (func (export "f") (param $x (ref $ft)) (drop (call_ref $ft (local.get $x)))))
