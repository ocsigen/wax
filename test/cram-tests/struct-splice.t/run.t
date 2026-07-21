A struct type definition may begin with `..` to inherit the supertype's fields
verbatim; the explicit fields that follow are the subtype's delta. This is
equivalent to repeating the inherited fields, and compiles to a struct listing
all of them.

  $ wax -f wat - <<'WAX'
  > type base = open { a: i32 };
  > type ext: base = { .., b: i64 };
  > fn read(x: &ext) -> i64 { x.a as i64_s + x.b; }
  > fn make() -> &ext { {ext| a: 1, b: 2}; }
  > WAX
  (type $base (sub (struct (field $a i32))))
  (type $ext (sub final $base (struct (field $a i32) (field $b i64))))
  (func $read (param $x (ref $ext)) (result i64)
    (i64.add (i64.extend_i32_s (struct.get $ext $a (local.get $x)))
      (struct.get $ext $b (local.get $x)))
  )
  (func $make (result (ref $ext)) (struct.new $ext (i32.const 1) (i64.const 2)))

The `..` form is preserved when reformatting Wax (it is not expanded):

  $ wax -f wax - <<'WAX'
  > type base = open { a: i32 };
  > type ext: base = { .., b: i64 };
  > type copy: base = { .. };
  > WAX
  type base = open { a: i32 }; type ext: base = { .., b: i64 }; type copy: base = { .. };

`..` may inherit from an earlier struct in the same `rec` group:

  $ wax -f wat - <<'WAX'
  > rec {
  >   type a = open { x: i32 };
  >   type b: a = { .., y: i32 };
  > }
  > fn f(p: &b) -> i32 { p.x + p.y; }
  > WAX
  (rec
    (type $a (sub (struct (field $x i32))))
    (type $b (sub final $a (struct (field $x i32) (field $y i32))))
  )
  (func $f (param $p (ref $b)) (result i32)
    (i32.add (struct.get $b $x (local.get $p))
      (struct.get $b $y (local.get $p)))
  )

`..` requires a supertype to inherit from:

  $ wax -f wat - <<'WAX'
  > type t = { .., x: i32 };
  > WAX
  Error:
    '..' requires a supertype to inherit fields from (write
    'type t: super = { .., ... }' ).
   ──➤  -:1:10
  1 │ type t = { .., x: i32 };
    ·          ^^^^^^^^^^^^^^
  2 │ 
  [128]

and the supertype must be a struct:

  $ wax -f wat - <<'WAX'
  > type ft = fn() -> i32;
  > type t: ft = { .., x: i32 };
  > WAX
  Error:
    '..' can only inherit fields from a struct supertype; 'ft' is not a struct.
   ──➤  -:2:9
  1 │ type ft = fn() -> i32;
  2 │ type t: ft = { .., x: i32 };
    ·         ^^
  3 │ 
  [128]

A delta field that repeats an inherited name is a duplicate:

  $ wax -f wat - <<'WAX'
  > type base = open { a: i32 };
  > type t: base = { .., a: i32 };
  > WAX
  Error: Several fields have the same name 'a'.
   ──➤  -:2:22
  1 │ type base = open { a: i32 };
    ·                    ^ other field here
  2 │ type t: base = { .., a: i32 };
    ·                      ^
  3 │ 
  [128]
