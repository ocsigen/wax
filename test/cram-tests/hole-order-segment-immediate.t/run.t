The hole-ordering check (which guards operand reordering) treated any variable
read as an evaluated value occurring before a hole '_'. But a memory / table /
data / elem name is a static immediate, not a stack value: in `t.init(e, _, _, _)`
both the table receiver `t` and the elem segment `e` are immediates, with only the
three operands on the stack. The check now skips such names, so a `table.init`
(here over the polymorphic stack of unreachable code) decompiles. Regression:
found by the differential-validation fuzzer.

  $ cat > m.wat <<'WAT'
  > (module
  >   (table 1 funcref)
  >   (elem funcref (ref.null func))
  >   (func (export "f")
  >     unreachable
  >     table.init 0 0))
  > WAT

  $ wax -i wat -f wax m.wat
  table t: &?func [1];
  elem e: &?func = [null as &?func];
  #[export = "f"]
  fn f() {
      unreachable;
      t.init(e, _, _, _);
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o /dev/null --validate
