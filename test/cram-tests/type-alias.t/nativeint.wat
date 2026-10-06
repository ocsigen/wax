(module
  (@if $portable_int
   (@then (@type $nativeint i64))
   (@else (@type $nativeint i32)))
  (import "nativeint" "Nativeint_val"
    (func $Nativeint_val (param (ref eq)) (result (@type $nativeint))))
  (import "nativeint" "caml_copy_nativeint"
    (func $caml_copy_nativeint (param (@type $nativeint)) (result (ref eq))))
  (type $digits (array (mut (@type $nativeint))))
  (func $id (export "id") (param $v (ref eq)) (result (ref eq))
    (local $n (@type $nativeint))
    (local.set $n (call $Nativeint_val (local.get $v)))
    (call $caml_copy_nativeint (local.get $n)))
  (func $digit (export "digit") (param $d (ref $digits)) (result (ref eq))
    (call $caml_copy_nativeint (array.get $digits (local.get $d) (i32.const 0)))))
