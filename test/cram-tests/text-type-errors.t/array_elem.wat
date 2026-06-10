(module
  (type $elem (struct))
  (type $arr (array (mut (ref $elem))))
  (func (param (ref $arr))
    (array.set $arr (local.get 0) (i32.const 0) (i32.const 1))))
