When a block's trailing value is a struct construction, the binding annotation
drops only when the struct resolves its own type. `vec3`'s three fields name it
uniquely, so it synthesizes independently and the annotation drops; `point`'s
fields are shared with `pair`, so the anonymous construction needs the context to
pin its type and the annotation is kept:

  $ wax structs.wat -f wax
  type point = { f: i32, f_2: i32 };
  type pair = { f: i32, f_2: i32 };
  type vec3 = { f: i32, f_2: i32, f_3: i32 };
  #[export]
  fn unique(a: i32) -> &vec3 {
      let x =
          do {
              { f: a, f_2: a, f_3: a };
          };
      x;
  }
  #[export]
  fn ambiguous(a: i32) -> &point {
      let x: &point =
          do {
              { f: a, f_2: a };
          };
      x;
  }

It round-trips: the field-unique construction re-resolves `vec3`, so the dropped
`(result (ref $vec3))` is recovered:

  $ wax structs.wat -f wax | wax -i wax -f wat
  (type $point (struct (field $f i32) (field $f_2 i32)))
  (type $pair (struct (field $f i32) (field $f_2 i32)))
  (type $vec3 (struct (field $f i32) (field $f_2 i32) (field $f_3 i32)))
  (func $unique (export "unique") (param $a i32) (result (ref $vec3))
    (local $x (ref $vec3))
    (local.set $x
      (block (result (ref $vec3))
        (struct.new $vec3 (local.get $a) (local.get $a) (local.get $a))))
    (local.get $x)
  )
  (func $ambiguous (export "ambiguous") (param $a i32) (result (ref $point))
    (local $x (ref $point))
    (local.set $x
      (block (result (ref $point))
        (struct.new $point (local.get $a) (local.get $a))))
    (local.get $x)
  )
