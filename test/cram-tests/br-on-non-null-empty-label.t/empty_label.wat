(module
  (type $t (func))
  (func (param $r (ref null $t))
    local.get $r
    br_on_non_null 0
    unreachable))
