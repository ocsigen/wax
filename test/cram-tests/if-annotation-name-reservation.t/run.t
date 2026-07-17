A module entity referenced only inside an instruction-level `(@if …)` body must
still reserve its Wax name in the enclosing function's namespace, or a generated
local name can shadow it. Here global `$x` is read only inside `(@then …)`; the
function's unnamed parameter must not be handed the generated name `x`.

  $ cat > f.wat <<'WAT'
  > (module
  >   (global $x f64 (f64.const 3.0))
  >   (func (param f64) (result f64)
  >     (@if $D (@then (global.get $x) (drop)))
  >     (local.get 0)))
  > WAT

  $ wax -i wat -f wax f.wat
  const x = 3.0;
  fn f(x_2: f64) -> f64 {
      #[if(D)]
      {
          _ = x;
      }
      x_2;
  }

With `-D D=true` the `(@if)` body reads the global `$x`, not the parameter:

  $ wax -i wat -f wax f.wat | wax -i wax -f wat -D D=true
  (global $x f64 (f64.const 3.0))
  (func $f (param $x_2 f64) (result f64)
    (drop (global.get $x))
    (local.get $x_2)
  )
