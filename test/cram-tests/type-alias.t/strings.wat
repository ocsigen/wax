(module
  (type $bytes (array (mut i8)))
  (@if $use_js_string
   (@then (@type $str externref))
   (@else (@type $str (ref $bytes))))
  (type $custom_operations (struct (field $id (@type $str)) (field $len i32)))
  (@if $use_js_string
   (@then
     (import "js" "length" (func $str_length (param externref) (result i32))))
   (@else
     (func $str_length (param $s (ref $bytes)) (result i32)
       (array.len (local.get $s)))))
  (func $ops_length (export "ops_length") (param $o (ref $custom_operations)) (result i32)
    (call $str_length (struct.get $custom_operations $id (local.get $o))))
  (func $nat (param $x (@type $str)) (result i32)
    (@if $use_js_string
      (@then (return (ref.is_null (local.get $x))))
      (@else (return (array.len (local.get $x)))))))
