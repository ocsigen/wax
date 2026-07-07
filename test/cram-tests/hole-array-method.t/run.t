An array method — `arr.fill(..)`, `arr.copy(..)`, `arr.init(..)` — is
receiver-first: the array operand is evaluated before the index/value/count
operands, both in `to_wasm` and in the type checker. `check_hole_order` must
mirror that, so when the receiver is a hole `_` (an array taken from the
enclosing operand stack) the following operands are not mistaken for values
pushed *before* the hole. Otherwise this fails with "This expression occurs
before a hole '_'."

  $ cat > fill.wat <<'WAT'
  > (module
  >   (type $arr (array (mut i32)))
  >   (func (export "f") (param (ref $arr))
  >     local.get 0
  >     (block (param (ref $arr))
  >       i32.const 0
  >       i32.const 7
  >       i32.const 3
  >       array.fill $arr)))
  > WAT

  $ wax -i wat -f wax fill.wat
  type arr = [mut i32];
  #[export]
  fn f(x: &arr) {
      x;
      do (&arr) {
          _.fill(0, 7, 3);
      }
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax fill.wat -o fill.wax && wax -i wax -f wasm fill.wax -o /dev/null --validate
