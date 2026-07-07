An exact reference type (the custom-descriptors proposal) is a reference to
exactly one concrete type, with no subtypes. Wax spells it with a [!] marker
between the [&]/[&?] sigil and the type name ([&!s], [&?!s]), mapping to the WAT
[(ref (exact $s))] form. It is a subtype of the corresponding inexact reference,
so an [&!s] flows where an [&s] is expected.

  $ wax --validate -X custom-descriptors exact.wax -f wat
  (type $s (struct (field $f i32)))
  
  (func $cast (export "cast") (param $x (ref null $s)) (result (ref (exact $s)))
    (ref.cast (ref (exact $s)) (local.get $x))
  )
  
  (func $test (export "test") (param $x (ref null (exact $s))) (result i32)
    (ref.test (ref (exact $s)) (local.get $x))
  )
  
  (func $widen (export "widen") (param $x (ref (exact $s))) (result (ref $s))
    (local.get $x)
  )




Exact references survive a binary round-trip.

  $ wax -X custom-descriptors exact.wax -f wasm -o exact.wasm
  $ wax -X custom-descriptors exact.wasm -f wax
  type s = { f: i32 };
  type t = fn(&?s) -> &!s;
  type t_2 = fn(&?!s) -> i32;
  type t_3 = fn(&!s) -> &s;
  #[export]
  fn cast(x: &?s) -> &!s {
      x as &!s;
  }
  #[export]
  fn test(x: &?!s) -> i32 {
      x is &!s;
  }
  #[export]
  fn widen(x: &!s) -> &s {
      x;
  }

A WAT module using exact references decompiles to the [&!] forms and back.

  $ wax -X custom-descriptors roundtrip.wat -f wax
  type s = { f: i32 };
  #[export]
  fn cast(x: &?s) -> &!s {
      x as &!s;
  }
  const g: &?!s = null;

Only a concrete type can be exact; [&!any] is rejected.

  $ wax check -X custom-descriptors bad.wax
  Error: Only a concrete type can be exact.
  
   ──➤  bad.wax:1:19
  1 │ fn f(x: &?any) -> &!any {
    ·                   ^^^^^
  2 │     x;
  3 │ }
  [128]
