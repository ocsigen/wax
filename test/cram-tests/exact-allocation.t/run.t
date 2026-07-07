A concrete allocation (struct or array construction) produces an exact
reference at the Wasm level: [struct.new]/[array.new] yield [(ref (exact $t))].
So a construction literal can be delivered where an [&!t] is required, without a
cast.

  $ wax --validate -X custom-descriptors alloc.wax -f wat
  (type $point (struct (field $x i32) (field $y i32)))
  (type $bytes (array i8))
  
  ;; A concrete allocation may be used where an exact reference is required.
  (func $make (export "make") (result (ref (exact $point)))
    (struct.new $point (i32.const 1) (i32.const 2))
  )
  
  (func $make_bytes (export "bytes") (result (ref (exact $bytes)))
    (array.new $bytes (i32.const 0) (i32.const 4))
  )




In synthesis position (no exact expectation) the plainer inexact type is kept —
an exact result is always usable where an inexact one is — so ordinary code is
unaffected.

  $ wax -X custom-descriptors roundtrip.wat -f wax
  type point = { f: i32, f_2: i32 };
  #[export]
  fn g() -> &point {
      { f: 1, f_2: 2 };
  }
