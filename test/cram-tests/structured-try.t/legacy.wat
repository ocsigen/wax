(module
  (tag $oops (param i32))
  (func $f (param $k i32) (result i32)
    (try (result i32)
      (do (local.get $k))
      (catch $oops)
      (catch_all (i32.const 0)))))
