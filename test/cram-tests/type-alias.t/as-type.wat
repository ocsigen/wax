(module
  (@type $n (ref null any))
  (type $t (sub $n (struct)))
  (func (export "g") (param $x (ref $n))))
