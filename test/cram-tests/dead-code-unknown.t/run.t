A type-unknown operation in unreachable code compiles to `unreachable` rather
than crashing the Wasm backend:

  $ wax convert -f wat dead.wax
  ;; An array access on a hole in unreachable code has an unknown receiver type.
  ;; It type-checks (dead code is permissive) and must compile without crashing:
  ;; the untranslatable, never-executed op becomes `unreachable`.
  (func $f (result i32) (unreachable)
                        (unreachable))
