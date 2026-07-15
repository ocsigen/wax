`become` performs a tail call for a genuine call (direct, indirect, or through
a reference), emitting the `return_call*` instructions. An intrinsic operation
has no tail-call instruction, so `become <intrinsic>` evaluates it and returns
its result — equivalent to `return <intrinsic>`.

  $ wax tc.wax -f wat
  (type $ft (func (param i32) (result i32)))
  
  (memory $mem 1)
  
  (func $g (param $x i32) (result i32) (local.get $x))
  
  ;; A genuine tail call still emits return_call.
  (func $direct (param $x i32) (result i32) (return_call $g (local.get $x)))
  
  ;; A call through a reference emits return_call_ref.
  (func $viaref (param $x i32) (param $p (ref $ft)) (result i32)
    (return_call_ref $ft (local.get $x) (local.get $p))
  )
  
  ;; An intrinsic cannot be a tail call, so it is evaluated and returned.
  (func $grow (param $n i32) (result i32)
    (return (memory.grow $mem (local.get $n)))
  )

The intrinsic's result must still match the function's declared result type,
the same tail-call constraint a genuine call is held to.

  $ wax check bad.wax
  Error: This instruction has type 'i32' but is expected to have type 'i64'.
   ──➤  bad.wax:4:23
  2 │ 
  3 │ // The intrinsic result must match the function's result type.
  4 │ fn f(n: i32) -> i64 { become mem.grow(n); }
    ·                       ^^^^^^^^^^^^^^^^^^
  5 │ 
  [128]
