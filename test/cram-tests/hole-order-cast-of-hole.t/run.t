The hole-ordering check (which guards operand reordering) treated a cast as a
value-producing expression. A cast that lowers to *no instruction* — its operand
is already a subtype of the target, e.g. the [(_ as f32)] operands of
[(_ as f32).min(_ as f32)] when the holes are already f32 — occupies its
operand's position and must be transparent to the check, but it used to trip
"This expression occurs before a hole". (Only casts on unreachable code were
exempt before, because there the hole stays polymorphic; here [f32.const] pins
the hole to a concrete f32, so the nop cast was missed.) Regression: found by the
differential-validation fuzzer.

  $ cat > m.wat <<'WAT'
  > (module
  >   (elem func)
  >   (func (export "f") (result f32)
  >     f32.const 1
  >     f32.const 2
  >     elem.drop 0
  >     f32.min))
  > WAT

  $ wax -i wat -f wax m.wat
  elem e: &func = [];
  #[export]
  fn f() -> f32 {
      1;
      2;
      e.drop();
      (_ as f32).min(_ as f32);
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o /dev/null --validate

A *real* conversion is not transparent: with f64 holes, [_ as f32] is an
[f32.demote_f64] that operates on the stack top, so [(_ as f32).min(_ as f32)]
cannot be reordered — it would compile to [demote; demote; f32.min], demoting the
wrong values. The check still rejects it:

  $ cat > bad.wax <<'WAX'
  > #[export = "f"]
  > fn f(x: f64, y: f64) -> f32 {
  >     x;
  >     y;
  >     nop;
  >     (_ as f32).min(_ as f32);
  > }
  > WAX

  $ wax -f wasm bad.wax -o /dev/null --validate
  Error: This expression occurs before a hole '_'.
   ──➤  bad.wax:6:6
  4 │     y;
  5 │     nop;
  6 │     (_ as f32).min(_ as f32);
    ·      ^^^^^^^^
  7 │ }
  8 │ 
  [128]
