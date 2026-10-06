A name declared in both branches of a conditional annotation may have a
different type in each: here an i64 in one and an i32 in the other. Code
shared by both branches that reads such a value has a width that depends on
the configuration, so the conversion to Wax states none there, and the type
checker resolves it in each configuration.

A function imported with a different result type in each branch:

  $ wax -f wax call.wat | tee call.wax
  #[if(p)]
  {
      import "n" fn v(&eq) -> i64;
  }
  #[else]
  {
      import "n" fn v(&eq) -> i32;
  }
  #[export]
  fn succ(x: &eq) -> i32 {
      _ = v(x);
      0;
  }
  $ wax -f wat call.wax
  (@if $p
    (@then (import "n" "v" (func $v (param (ref eq)) (result i64))))
    (@else (import "n" "v" (func $v (param (ref eq)) (result i32))))
  )
  (func $succ (export "succ") (param $x (ref eq)) (result i32)
    (drop (call $v (local.get $x)))
    (i32.const 0)
  )

A global:

  $ wax -f wax global.wat | tee global.wax
  #[if(p)]
  {
      let g: i64 = 0;
  }
  #[else]
  {
      let g = 0;
  }
  #[export]
  fn f() {
      _ = g;
  }
  $ wax -f wat global.wax
  (@if $p
    (@then (global $g (mut i64) (i64.const 0)))
    (@else (global $g (mut i32) (i32.const 0)))
  )
  (func $f (export "f") (drop (global.get $g)))

A struct field:

  $ wax -f wax struct.wat | tee struct.wax
  #[if(p)]
  {
      type s = { f: i64 };
  }
  #[else]
  {
      type s = { f: i32 };
  }
  #[export]
  fn f(x: &s) {
      _ = x.f;
  }
  $ wax -f wat struct.wax
  (@if $p
    (@then (type $s (struct (field $f i64))))
    (@else (type $s (struct (field $f i32))))
  )
  (func $f (export "f") (param $x (ref $s))
    (drop (struct.get $s $f (local.get $x)))
  )

A function type, through call_ref and call_indirect:

  $ wax -f wax call_ref.wat | tee call_ref.wax
  #[if(p)]
  {
      type ft = fn() -> i64;
  }
  #[else]
  {
      type ft = fn() -> i32;
  }
  #[export]
  fn f(x: &ft) {
      _ = x();
  }
  $ wax -f wat call_ref.wax
  (@if $p
    (@then (type $ft (func (result i64))))
    (@else (type $ft (func (result i32))))
  )
  (func $f (export "f") (param $x (ref $ft))
    (drop (call_ref $ft (local.get $x)))
  )
  $ wax -f wax call_indirect.wat | tee call_indirect.wax
  #[if(p)]
  {
      type ft = fn() -> i64;
  }
  #[else]
  {
      type ft = fn() -> i32;
  }
  table t: &?func [1];
  #[export]
  fn f() {
      _ = (t[0] as &?ft)();
  }
  $ wax -f wat call_indirect.wax
  (@if $p
    (@then (type $ft (func (result i64))))
    (@else (type $ft (func (result i32))))
  )
  (table $t 1 funcref)
  (func $f (export "f") (drop (call_indirect $t (type $ft) (i32.const 0))))
