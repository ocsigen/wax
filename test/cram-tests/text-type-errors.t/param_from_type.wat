(module
  (type $t (struct))
  (type $ft (func (param (ref $t))))
  (func (type $ft)
    (drop (i32.add (local.get 0) (i32.const 1)))))
