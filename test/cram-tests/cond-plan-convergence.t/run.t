The Wasm-to-Wax conversion mirrors, in its stack model, the branch the typer's
configuration plan selects at each conditional. It first builds that plan from
the source's shape; but the emitted Wax can have a different field-level shape
(here the standalone conditional export becomes a guard on `f`, so its `(@if)`
field disappears), and the typer, like every later re-parse, plans from the
emitted shape. Decisions are reached in stream order, so the dropped field's
literal `$A` no longer constrains the body: under the source plan `not $A` is
unsatisfiable there and the else branch is selected, under the emitted plan the
then branch is. The conversion detects the disagreement and converts again with
the emitted shape's plan, so the printed module is the one the re-parse types.

  $ cat > drop.wat <<'WAT'
  > (module
  >   (func $f (export "f") (param i32) (result i32) (local.get 0))
  >   (@if $A (@then (export "g" (func $f))))
  >   (func $h (result i64)
  >     (@if (not $A) (@then i64.const 1) (@else i64.const 2))))
  > WAT
  $ wax -i wat -f wax drop.wat -o drop.wax && cat drop.wax
  #[export]
  #[export = "g", if(A)]
  fn f(x: i32) -> i32 {
      x;
  }
  fn h() -> i64 {
      #[if(not(A))]
      {
          1;
      }
      #[else]
      {
          2;
      }
  }
  $ wax drop.wax -f wat
  (func $f (export "f") (param $x i32) (result i32) (local.get $x))
  (@if $A (@then (export "g" (func $f))))
  (func $h (result i64)
    (@if (not $A) (@then (i64.const 1)) (@else (i64.const 2)))
  )
  $ wax drop.wax -f wax | diff - drop.wax && echo stable
  stable
