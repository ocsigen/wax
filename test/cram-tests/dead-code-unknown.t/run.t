A type-unknown operation in unreachable code compiles to `unreachable` rather
than crashing the Wasm backend:

  $ wax convert -f wat dead.wax
  ;; An array access on a hole in unreachable code has an unknown receiver type.
  ;; It type-checks (dead code is permissive) and must compile without crashing:
  ;; the untranslatable, never-executed op becomes `unreachable`.
  (func $f (result i32) (unreachable)
                        (unreachable))
  
  ;; A `let` whose initializer is an unknown-typed (dead) value: the local is
  ;; still declared (type irrelevant) so later references resolve.
  (type $box (struct (field $v i32)))
  
  (func $g
    (local $b i32)
    (unreachable)
    (local.set $b (unreachable))
    (drop (local.get $b))
  )
