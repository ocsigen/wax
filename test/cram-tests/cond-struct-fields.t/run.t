A struct type may be declared in both branches of an [(@if …)] with different
fields. Converting to Wax keeps each branch's field names apart, so a field
declaration or access in one branch is not resolved against the other branch's
fields (which used to fail with "This reference resolves to nothing").

  $ wax fields.wat -f wax
  type f = fn();
  type c = open { func: &?f };
  #[if(mode = "a")]
  {
      type d: c = open { .., g: i32 };
      #[export]
      fn get(x: &d) -> i32 {
          x.g;
      }
      #[export]
      fn make() -> &d {
          { func: null, g: 1 };
      }
  }
  #[else]
  {
      type d = open { g: i64 };
      #[export]
      fn get(x: &d) -> i32 {
          x.g as i32;
      }
      #[export]
      fn make() -> &d {
          { g: 2 };
      }
  }

The Wax output converts back to the same per-branch types.

  $ wax fields.wat -f wax -o fields.wax
  $ wax fields.wax -f wat
  (type $f (func))
  (type $c (sub (struct (field $func (ref null $f)))))
  (@if (= $mode "a")
    (@then
      (type $d (sub $c (struct (field $func (ref null $f)) (field $g i32))))
      (func $get (export "get") (param $x (ref $d)) (result i32)
        (struct.get $d $g (local.get $x)))
      (func $make (export "make") (result (ref $d))
        (struct.new $d (ref.null $f) (i32.const 1))))
    (@else
      (type $d (sub (struct (field $g i64))))
      (func $get (export "get") (param $x (ref $d)) (result i32)
        (i32.wrap_i64 (struct.get $d $g (local.get $x))))
      (func $make (export "make") (result (ref $d))
        (struct.new $d (i64.const 2))))
  )
