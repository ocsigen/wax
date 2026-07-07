struct.set / array.set / table.set return no value, so they must not be
inlined into value position. The decompiler pushed them onto its operand stack
as if they produced one result, so in unreachable code (a polymorphic stack) a
following instruction could grab the set as its operand, e.g. `(s.f = 5).eqz()`,
which then failed with "An expression is expected here. This instruction returns
0 values." Push them with arity 0, like local.set/global.set. Regression: found
by the differential-validation fuzzer.

  $ cat > ss.wat <<'WAT'
  > (module
  >   (type $s (struct (field (mut i32))))
  >   (func (export "f") (result i32)
  >     unreachable
  >     struct.new_default $s
  >     i32.const 5
  >     struct.set $s 0
  >     i32.eqz))
  > WAT

The set stays a statement and the following instruction takes a hole operand:

  $ wax -i wat -f wax ss.wat
  type s = { f: mut i32 };
  #[export]
  fn f() -> i32 {
      unreachable;
      {s| .. }.f = 5;
      !(_ as i32);
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax ss.wat -o ss.wax && wax -i wax -f wasm ss.wax -o /dev/null --validate
