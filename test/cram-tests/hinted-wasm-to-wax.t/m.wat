(module
  (func $f)
  (elem $e declare func $f)
  (func (param i32)
    local.get 0
    (@metadata.code.branch_hint "\01")
    if
      elem.drop $e
    end))
