(module
  (type $t (struct))
  (func (param i32) (result i32)
    local.get 0
    (@metadata.code.branch_hint "\01")
    if (result i32)
      i32.const 1
    else
      i32.const 2
    end)
  (func (param i32)
    block
      local.get 0
      (@metadata.code.branch_hint "\00")
      br_if 0
    end)
  ;; A hint on a br_on_* branch (all conditional branches are supported).
  (func (param anyref) (result (ref $t))
    local.get 0
    (@metadata.code.branch_hint "\01")
    br_on_cast 0 anyref (ref $t)
    unreachable))
