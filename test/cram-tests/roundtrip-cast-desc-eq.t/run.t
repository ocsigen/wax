`ref.cast_desc_eq` (the custom-descriptors descriptor-equality cast) is a genuine
operation, not a redundant type pin: the Wax typer never drops a `CastDesc` while
simplifying (its `Cast`-arm always re-emits one), so unlike a plain `ref.cast` it
round-trips and is compared by the faithful-round-trip fuzz oracle. A live cast
keeps both operands; a dead-code cast pins its holes (`From_wasm.pin_descriptor`
grounds the descriptor operand, and the `?descriptor(...)` surface recovers the
value operand).

  $ cat > m.wat <<'WAT'
  > (module (@feature "custom-descriptors")
  >   (rec
  >     (type $a (sub (descriptor $b) (struct)))
  >     (type $b (sub (describes $a) (struct))))
  >   (func $live (param (ref null any) (ref null $b)) (result (ref null $a))
  >     (ref.cast_desc_eq (ref null $a) (local.get 0) (local.get 1)))
  >   (func $dead (result (ref null $a))
  >     unreachable
  >     ref.cast_desc_eq (ref null $a)))
  > WAT
  $ wax -i wat -f wax --faithful m.wat | sed -n '/fn live/,$p'
  fn live(x: &?any, x_2: &?b) -> &?a {
      x as ?descriptor(x_2);
  }
  fn dead() -> &?a {
      unreachable;
      _ as ?descriptor(_ as &?b);
  }

Both round-trip back to a `ref.cast_desc_eq`:

  $ wax -i wat -f wax --faithful m.wat -o m.wax && wax -i wax -f wat m.wax | grep -oE 'ref.cast_desc_eq'
  ref.cast_desc_eq
  ref.cast_desc_eq
