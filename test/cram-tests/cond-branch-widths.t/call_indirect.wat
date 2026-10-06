(module
  (@if $p
   (@then (type $ft (func (result i64))))
   (@else (type $ft (func (result i32)))))
  (table $t 1 funcref)
  (func (export "f") (drop (call_indirect $t (type $ft) (i32.const 0)))))
