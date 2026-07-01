A try_table catch clause branches to a label, so it references it. [refs_label]
omitted the catch labels, so a catch branching back to an enclosing `if`'s label
was not seen as a self-branch; if-result inference then ran and (under simplify)
dropped the if's `=> f64` annotation, leaving the label with no result — and the
catch, which delivers the tag's value to it, failed with "This instruction
provides 1 value(s) but 0 was/were expected." Regression: differential-validation
fuzzer.

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

The catch is recognised as a use of 'l_2, so its `=> f64` is kept:

  $ wax -i wat -f wax c.wat
  tag e(f64);
  #[export = "f"]
  fn f(x: i32) {
      _ =
          'l_2: if x => f64 {
              try {
                  1;
              } catch [ e -> 'l_2]
          } else {
              unreachable;
          };
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax c.wat -o c.wax && wax -i wax -f wasm c.wax -o /dev/null --validate
