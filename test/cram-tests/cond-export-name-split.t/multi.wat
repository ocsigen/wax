(module
   (import "x" "getuid" (func $getuid (result i32)))
   (@if $wasi
   (@then
      (func (export "unix_getuid") (export "caml_unix_getuid")
            (export "unix_geteuid") (export "caml_unix_geteuid")
         (param (ref eq)) (result (ref eq))
         (ref.i31 (i32.const 1))))
   (@else
      (func (export "unix_getuid") (export "caml_unix_getuid")
         (param (ref eq)) (result (ref eq))
         (ref.i31 (call $getuid)))
      (func (export "unix_geteuid") (export "caml_unix_geteuid")
         (param (ref eq)) (result (ref eq))
         (ref.i31 (call $getuid))))))
