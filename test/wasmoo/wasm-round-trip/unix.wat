(import "bindings" "gettimeofday" (func $gettimeofday (result f64)))
(import "bindings" "gmtime" (func $gmtime (param f64) (result (ref eq))))
(import "bindings" "localtime"
  (func $localtime (param f64) (result (ref eq)))
)
(import "bindings" "mktime"
  (func $mktime (param i32 i32 i32 i32 i32 i32) (result f64))
) (type $block (array (mut (ref eq)))) (type $float (struct (field $f f64)))
(func $unix_gettimeofday (export "unix_gettimeofday")
  (export "caml_unix_gettimeofday") (param $x (ref eq)) (result (ref eq))
  (struct.new $float (call $gettimeofday))
)
(func $caml_alloc_tm
  (export

    "caml_alloc_tm")
  (param $sec i32) (param $min i32) (param $hour i32) (param $mday i32)
  (param $mon i32) (param $year i32) (param $wday i32) (param $yday i32)
  (param $isdst i32) (result (ref eq))
  (array.new_fixed $block 10 (ref.i31 (i32.const 0))
    (ref.i31 (local.get $sec)) (ref.i31 (local.get $min))
    (ref.i31 (local.get $hour)) (ref.i31 (local.get $mday))
    (ref.i31 (local.get $mon)) (ref.i31 (local.get $year))
    (ref.i31 (local.get $wday)) (ref.i31 (local.get $yday))
    (ref.i31 (local.get $isdst)))
)
(func $unix_gmtime (export "unix_gmtime") (export "caml_unix_gmtime")
  (param $x (ref eq)) (result (ref eq))
  (call $gmtime (struct.get $float $f (ref.cast (ref $float) (local.get $x))))
)
(func $unix_localtime (export "unix_localtime")
  (export "caml_unix_localtime") (param $x (ref eq)) (result (ref eq))
  (call $localtime
    (struct.get $float $f (ref.cast (ref $float) (local.get $x))))
)
(func $unix_time (export "unix_time") (export "caml_unix_time")
  (param $x (ref eq)) (result (ref eq))
  (struct.new $float (f64.floor (call $gettimeofday)))
)
(func $unix_mktime (export "unix_mktime") (export "caml_unix_mktime")
  (param $x (ref eq)) (result (ref eq))
  (local $tm (ref $block)) (local $t f64)
  (local.set $tm (ref.cast (ref $block) (local.get $x)))
  (local.set $t
    (f64.div
      (call $mktime
        (i32.add
          (i31.get_s
            (ref.cast (ref i31)
              (array.get $block (local.get $tm) (i32.const 6))))
          (i32.const 1900))
        (i31.get_s
          (ref.cast (ref i31)
            (array.get $block (local.get $tm) (i32.const 5))))
        (i31.get_s
          (ref.cast (ref i31)
            (array.get $block (local.get $tm) (i32.const 4))))
        (i31.get_s
          (ref.cast (ref i31)
            (array.get $block (local.get $tm) (i32.const 3))))
        (i31.get_s
          (ref.cast (ref i31)
            (array.get $block (local.get $tm) (i32.const 2))))
        (i31.get_s
          (ref.cast (ref i31)
            (array.get $block (local.get $tm) (i32.const 1)))))
      (f64.const 1000)))
  (array.new_fixed $block 3 (ref.i31 (i32.const 0))
    (struct.new $float (local.get $t)) (call $localtime (local.get $t)))
)
(func $unix_inet_addr_of_string (export "unix_inet_addr_of_string")
  (export "caml_unix_inet_addr_of_string")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
