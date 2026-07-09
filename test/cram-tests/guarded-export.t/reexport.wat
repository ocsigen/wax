(module
   (func $fmt32 (export "fmt32")
      (param $v (ref eq)) (result (ref eq))
      (local.get $v))
   (@if $portable
      (@then
         (import "m" "fmt64" (func $fmt64 (param (ref eq)) (result (ref eq))))
         (export "fmt" (func $fmt64)))
      (@else
         (export "fmt" (func $fmt32)))))
