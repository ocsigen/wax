`extern.convert_any` / `any.convert_extern` are cross-hierarchy operations that
must survive a round trip. Their Wax surface is a plain `as &?extern` / `as &?any`
on an anyref / externref operand. When the operand re-parses type-ADAPTIVELY (a
null, a hole, a `select`/`?:` whose arms are adaptive), a bare `operand as &?extern`
lets the operand take the extern hierarchy and collapses the convert into a plain
`ref.null extern`. `From_wasm` grounds such an operand with the source-hierarchy
cast (`(_?_:_) as &?any`), and the Wax typer keeps that inner cast rather than
dropping it (`reparse_adaptive` mirrors the pin). A concrete-reference operand
fixes the convert on its own, so it gets no pin (no noise on the default path).

  $ cat > m.wat <<'WAT'
  > (module
  >   (func $sel_nulls (result externref)
  >     unreachable
  >     ref.null any
  >     ref.null any
  >     i32.const 0
  >     select (result anyref)
  >     extern.convert_any)
  >   (func $sel_conc (param anyref anyref i32) (result externref)
  >     local.get 0 local.get 1 local.get 2
  >     select (result anyref)
  >     extern.convert_any))
  > WAT
  $ wax -i wat -f wax --faithful m.wat
  fn sel_nulls() -> &?extern {
      unreachable;
      (0?null:null) as &?any as &?extern;
  }
  fn sel_conc(x: &?any, x_2: &?any, x_3: i32) -> &?extern {
      (x_3?x:x_2) as &?extern;
  }

Both keep `extern.convert_any` across the round trip (the adaptive select of nulls
via the kept inner `as &?any`, the concrete select directly):

  $ wax -i wat -f wax --faithful m.wat -o m.wax && wax -i wax -f wat m.wax | grep -oE 'extern.convert_any'
  extern.convert_any
  extern.convert_any
