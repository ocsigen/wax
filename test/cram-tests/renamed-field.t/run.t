A struct subtype may name an inherited field differently from its supertype.
Wax looks a field up by name in the receiver's type, so a field access
through a subtype would find another field, or none. Converting to Wax
ascribes the receiver the access's own type instead.

  $ wax -f wax renamed.wat | tee renamed.wax
  type s1 = open { f: mut i32 };
  type s2: s1 = open { a: mut i32, f: i32 };
  type s3: s2 = { b: mut i32, c: i32 };
  #[export]
  fn get(x: &s2) -> i32 {
      (x : &?s1).f;
  }
  #[export]
  fn set(x: &s2) {
      (x : &?s1).f = 1;
  }
  #[export]
  fn get3(x: &s3) -> i32 {
      (x : &?s2).f + (x : &?s1).f;
  }

Converting back reads the same fields.

  $ wax -f wat renamed.wax
  (type $s1 (sub (struct (field $f (mut i32)))))
  (type $s2 (sub $s1 (struct (field $a (mut i32)) (field $f i32))))
  (type $s3 (sub final $s2 (struct (field $b (mut i32)) (field $c i32))))
  (func $get (export "get") (param $x (ref $s2)) (result i32)
    (struct.get $s1 $f (local.get $x))
  )
  (func $set (export "set") (param $x (ref $s2))
    (struct.set $s1 $f (local.get $x) (i32.const 1))
  )
  (func $get3 (export "get3") (param $x (ref $s3)) (result i32)
    (i32.add (struct.get $s2 $f (local.get $x))
      (struct.get $s1 $f (local.get $x)))
  )
