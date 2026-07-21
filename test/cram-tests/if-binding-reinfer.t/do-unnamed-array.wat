(module
  (type $t (array i8))
  (func $f
    (local $x (ref $t))
    (local.set $x
      (block (result (ref $t))
        (array.new_fixed $t 1 (i32.const 1))))))
