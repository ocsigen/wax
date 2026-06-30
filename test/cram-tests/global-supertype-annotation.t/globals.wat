(module
  (type $s (sub (struct (field i32))))
  (func $f (result i32) (i32.const 0))
  (global $gc funcref (ref.func $f))
  (global $gstruct eqref (struct.new $s (i32.const 7)))
  (global $gm (mut funcref) (ref.func $f))
  (global $gnull anyref (ref.null any))
)
