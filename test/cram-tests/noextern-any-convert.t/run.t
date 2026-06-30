any.convert_extern accepts any externref operand, including nullexternref
(noextern). To_wasm's cast lowering matched only the extern heap type for the
externref-to-anyref conversion, so a noextern operand fell through to a plain
ref.cast across hierarchies, producing a module that fails to validate (expected
anyref, found nullexternref). Match noextern too. Regression: found by the smith
fuzzer.

  $ cat > t.wat <<'WAT'
  > (module
  >   (global $g (mut anyref) (ref.null any))
  >   (func (export "f")
  >     ref.null noextern
  >     any.convert_extern
  >     global.set $g))
  > WAT
  $ wax -i wat -f wax t.wat -o t.wax && wax -i wax -f wasm t.wax -o /dev/null --validate
