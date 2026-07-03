(module
  (func $target)
  (func (param i32)
    local.get 0
    (@metadata.code.branch_hint "\01")
    if
      ref.func $target
      drop
    end))
