(module
  (func $parse (param $x i32) (result i32 i32 i32 i32)
    (i32.const 1) (i32.const 2) (i32.const 3) (i32.const 4))

  ;; A multi-value call whose results are peeled off by a run of local.set
  ;; folds back into a single multi-binding let.
  (func $basic (param $x i32) (result i32)
    (local $a i32) (local $b i32) (local $c i32) (local $d i32)
    (call $parse (local.get $x))
    (local.set $d) (local.set $c) (local.set $b) (local.set $a)
    (local.get $a))

  ;; A discarded result becomes a `_` binding.
  (func $dropped (result i32)
    (local $a i32) (local $c i32)
    (call $parse (i32.const 0))
    (local.set $c) (drop) (drop) (local.set $a)
    (i32.add (local.get $a) (local.get $c)))

  ;; The run consumed is exactly the call's arity: with a value already on the
  ;; stack below the call, the extra local.set draws from it, not the call, so
  ;; only the two call results fold.
  (func $arity (param $p i32) (result i32)
    (local $a i32) (local $b i32) (local $c i32)
    (local.get $p)
    (call $two)
    (local.set $a) (local.set $b) (local.set $c)
    (i32.add (i32.add (local.get $a) (local.get $b)) (local.get $c)))

  (func $two (result i32 i32) (i32.const 10) (i32.const 20)))
