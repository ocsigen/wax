(module
  (@if $wasi
    (@then
      (func (export "init") (param (ref eq)) (result (ref eq))
        (local.get 0)))
    (@else
      (func (export "init") (param (ref eq)) (result (ref eq))
        (local.get 0)))))
