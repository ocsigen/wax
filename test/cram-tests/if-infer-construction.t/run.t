A value-producing `if` in synthesis position (here the receiver of a field
access) whose branches are construction literals now infers its result type, so
the `=> T` is dropped. The constructions keep enough to re-synthesize their own
type — here the field names match a single struct, so even the type name drops:

  $ wax point.wat -f wax
  type point = { x: i32, y: i32 };
  #[export]
  fn f(c: i32) -> i32 {
      (if c {
           { x: 1, y: 2 };
       } else {
           { x: 3, y: 4 };
       }.x);
  }

It still round-trips: re-converting reproduces the original `(if (result …))`:

  $ wax point.wat -f wax | wax -i wax -f wat
  (type $point (struct (field $x i32) (field $y i32)))
  (func $f (export "f") (param $c i32) (result i32)
    (struct.get $point $x
      (if (result (ref $point)) (local.get $c)
        (then (struct.new $point (i32.const 1) (i32.const 2)))
        (else (struct.new $point (i32.const 3) (i32.const 4)))))
  )

When the field names do not pin a unique struct type, the type name is kept on
the construction (so it stays re-synthesizable) while `=> T` still drops:

  $ wax ambiguous.wat -f wax | wax -i wax -f wat
  (type $a (struct (field $x i32) (field $y i32)))
  (type $b (struct (field $x i32) (field $y i32)))
  (func $f (export "f") (param $c i32) (result i32)
    (struct.get $a $x
      (if (result (ref $a)) (local.get $c)
        (then (struct.new $a (i32.const 1) (i32.const 2)))
        (else (struct.new $a (i32.const 3) (i32.const 4)))))
  )
