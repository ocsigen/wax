(module
  (func (export "add") (param i64 i64 i64 i64) (result i64 i64)
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    i64.add128)
  (func (export "mul") (param i64 i64) (result i64 i64)
    local.get 0
    local.get 1
    i64.mul_wide_u))
