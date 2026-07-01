An `if` used in operand position, with a branch whose value is produced after a
terminator (here `unreachable`), so it is a dead fall-through on an unreachable
stack. Inferring the if's result must take that dead value as the branch's exit
value (its type still has to agree with the other branch) rather than leaving it
as a stray value. The simplify pass drops the inferable `=> i32` annotation, and
without this the re-typed `if` reported "This value remains on the stack."
Regression: found by the differential-validation fuzzer.

  $ cat > g.wat <<'WAT'
  > (module
  >   (func (export "f") (result i32)
  >     (i32.add
  >       (if (result i32) (i32.const 1)
  >         (then unreachable (i32.const 5))
  >         (else (i32.const 7)))
  >       (i32.const 9))))
  > WAT

The if's result is inferred (the `=> i32` annotation is dropped as redundant):

  $ wax -i wat -f wax g.wat
  #[export = "f"]
  fn f() -> i32 {
      (if 1 {
           unreachable;
           5;
       } else {
           7;
       } + 9);
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax g.wat -o g.wax && wax -i wax -f wasm g.wax -o /dev/null --validate
