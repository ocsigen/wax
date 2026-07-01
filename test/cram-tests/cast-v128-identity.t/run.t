An identity cast [v128 as v128] is a no-op, like [i32 as i32]. The typer accepts
it, but [to_wasm]'s cast lowering listed the identity (Nop) case only for the
scalar numeric types, so a v128 self-cast fell through to `assert false`. It now
lowers to nothing. Regression: found by the cast-lattice sweep.

  $ echo '#[export="f"] fn f(v: v128) -> v128 { v as v128; }' > m.wax
  $ wax m.wax -f wat
  (func $f (export "f") (param $v v128) (result v128) (local.get $v))
