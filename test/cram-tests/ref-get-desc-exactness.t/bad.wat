(module
  (rec
    (type $a (sub (descriptor $b) (struct)))
    (type $b (sub (describes $a) (struct)))
    (type $c (sub $a (descriptor $d) (struct)))
    (type $d (sub $b (describes $c) (struct))))
  (func (param (ref (exact $c))) (result (ref (exact $b)))
    (ref.get_desc $a (local.get 0))))
