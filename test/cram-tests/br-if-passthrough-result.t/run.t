A value delivered by `br_if` (or `br_on_null`) stays on the stack on the
not-taken path, typed as the *target block's result* — not as its own, possibly
narrower, operand. Typing it by the operand was unsound: a block result inferred
wider than the operand let the pass-through be used at the narrower operand type,
which has no valid Wasm translation.

The pass-through is now typed as the block's result. When the result is known (an
annotation, or the context type here), a value used at a narrower type is
correctly rejected:

  $ cat > bad.wax <<'WAX'
  > fn g(x: &i31) {}
  > #[export = "f"]
  > fn f(c: i32) -> &any {
  >     'l: do {
  >         g(br_if 'l (5 as &i31, c));
  >         null as &any;
  >     }
  > }
  > WAX
  $ wax -f wasm bad.wax -o /dev/null
  Error: This instruction has type &any but is expected to have type &i31.
   ──➤  bad.wax:5:11
  3 │ fn f(c: i32) -> &any {
  4 │     'l: do {
  5 │         g(br_if 'l (5 as &i31, c));
    ·           ^^^^^^^^^^^^^^^^^^^^^^^
  6 │         null as &any;
  7 │     }
  [128]

Delivering a subtype whose pass-through is not used at a narrower type stays
valid, so a faithfully decompiled module is not over-rejected — here a `br_if`
delivers a `&i31` to an `anyref` block and the pass-through is dropped:

  $ cat > ok.wat <<'WAT'
  > (module
  >   (func (export "f") (param $c i32) (result anyref)
  >     (block $l (result anyref)
  >       (drop (br_if $l (ref.i31 (i32.const 5)) (local.get $c)))
  >       (ref.null any))))
  > WAT
  $ wax -i wat -f wax ok.wat
  #[export]
  fn f(c: i32) -> &?any {
      'l: do {
          _ = br_if 'l (5 as &i31, c);
          null;
      }
  }
  $ wax -i wat -f wax ok.wat -o ok.wax && wax -i wax -f wasm ok.wax -o /dev/null --validate
