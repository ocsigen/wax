(module
  ;; $g has a branch-dependent arity: a 0-arg no-op when $wasi, a 1-arg import
  ;; otherwise. The (valid) WAT relies on the folded-call trick — under $wasi
  ;; the operand flows through to struct.new. But $h is unconditional, so the
  ;; call's arity is undetermined and there is no single Wax conversion.
  (type $t (struct (field i32)))
  (@if $wasi
    (@then (func $g))
    (@else (import "m" "g" (func $g (param i32) (result i32)))))
  (func $h (result (ref $t))
    (struct.new $t (call $g (i32.const 1)))))
