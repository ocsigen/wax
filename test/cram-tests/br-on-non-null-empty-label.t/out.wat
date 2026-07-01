(type $t (func))
(func (param $r (ref null $t)) (result (ref $t))
  block (result (ref $t)) local.get $r br_on_non_null 0 unreachable end
)
