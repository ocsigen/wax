`x as &extern` on an `i32` lowers as `extern.convert_any (ref.i31 x)`; when `x`
is a constant the whole expression is constant, so it is allowed in a constant
position (a global or element initializer). The constant checker used to demand
the operand already be an `any` reference and rejected the `i32`.

  $ wax -i wax -f wat g.wax
  (global $e (mut externref) (extern.convert_any (ref.i31 (i32.const 0))))
  (func $get (export "get") (result externref) (global.get $e))
