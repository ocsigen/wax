(module
  (@type $r (ref null $t))
  (type $s (struct (field (@type $r))))
  (type $t (struct))
  (func (export "f") (param (@type $r))))
