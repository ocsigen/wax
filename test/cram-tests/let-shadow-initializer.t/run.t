A `let` binding is not in scope within its own initializer, so a `let` that
shadows an outer binding (a parameter or an enclosing local) must still read the
*outer* one from its initializer. To_wasm renames the new local to avoid the
wasm-level name collision (`$x` -> `$x_2`), but it must bring that new name into
scope only after lowering the initializer — otherwise the initializer's
reference binds to the new (renamed) local, producing wasm that reads an
uninitialized slot (a silent miscompile) or fails validation outright.

  $ wax shadow.wax -f wat
  ;; A `let` that shadows a parameter: the initializer must still read the
  ;; outer binding, even after To_wasm renames the new local to avoid the
  ;; wasm-level name collision.
  (func $f (param $x i32) (result i32)
    (local $x_2 i32)
    (local.set $x_2 (i32.add (local.get $x) (i32.const 1)))
    (local.get $x_2)
  )
  
  ;; The shadowed name appears in an `if` condition inside the initializer.
  (func $g (param $x i32) (result i32)
    (local $x_2 i32)
    (local.set $x_2
      (if (result i32) (local.get $x)
        (then (i32.const 10))
        (else (i32.const 20))))
    (local.get $x_2)
  )

