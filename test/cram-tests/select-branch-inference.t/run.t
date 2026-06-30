When a select (`?:`) appears in a checking context — a call argument, or an
annotated binding — the expected type is pushed into both value branches, so a
construction there can drop its type name even when its field set is ambiguous
(only the expected type can pin it). The bare branch literals re-resolve through
the same select context on re-parse, so the conversion round-trips.

  $ wax -i wat -f wax select.wat
  type s = open { f: i32 };
  type t = open { f: i32 };
  fn g(&s) -> i32 {
      0;
  }
  fn arg(c: i32) -> i32 {
      g(c?{ f: 1 }:{ f: 2 });
  }
  fn bound(c: i32) -> &s {
      let x: &s = c?{ f: 3 }:{ f: 4 };
      x;
  }

The dropped names round-trip: re-reading the Wax above re-resolves each bare
branch literal to (ref $s) from the select's context.

  $ wax -i wat -f wax select.wat | wax -i wax -f wat --validate
  (type $s (sub (struct (field $f i32))))
  (type $t (sub (struct (field $f i32))))
  (func $g (param (ref $s)) (result i32) (i32.const 0))
  (func $arg (param $c i32) (result i32)
    (call $g
      (select (result (ref $s)) (struct.new $s (i32.const 1))
        (struct.new $s (i32.const 2)) (local.get $c)))
  )
  (func $bound (param $c i32) (result (ref $s))
    (local $x (ref $s))
    (local.set $x
      (select (result (ref $s)) (struct.new $s (i32.const 3))
        (struct.new $s (i32.const 4)) (local.get $c)))
    (local.get $x)
  )
