A try_table catch clause branching back to an enclosing `if`'s label used to
confuse if-result inference: the label was left with no result, and the catch,
which delivers the tag's value to it, failed with "This instruction provides 1
value(s) but 0 was/were expected." With if-blocks inferred uniformly like the
other block forms, the construct now round-trips (the result type lands on the
`try`). Regression: differential-validation fuzzer.

  $ cat > c.wat <<'WAT'
  > (module
  >   (tag $e (param f64))
  >   (func (export "f") (param i32)
  >     (drop
  >       (if $l (result f64) (local.get 0)
  >         (then
  >           (try_table (result f64) (catch $e $l)
  >             (f64.const 1)))
  >         (else (unreachable))))))
  > WAT

The result type is recovered (on the `try`), so the catch's value has a target:

  $ wax -i wat -f wax c.wat
  tag e(f64);
  #[export = "f"]
  fn f(x: i32) {
      _ =
          'l: if x {
              try f64 {
                  1;
              } catch [ e -> 'l]
          } else {
              unreachable;
          };
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax c.wat -o c.wax && wax -i wax -f wasm c.wax -o /dev/null --validate
