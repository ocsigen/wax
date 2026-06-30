extern.convert_any accepts any operand in the any hierarchy, including eqref.
To_wasm's cast lowering listed the other any-hierarchy heap types (any, i31,
struct, array, concrete types, none) but omitted eq, so an eqref-to-externref
conversion fell through to a plain ref.cast across hierarchies, producing a
module that fails to validate. Regression: found by the smith fuzzer.

  $ cat > t.wat <<'WAT'
  > (module
  >   (global $g (mut externref) (ref.null extern))
  >   (func (export "f")
  >     ref.null eq
  >     extern.convert_any
  >     global.set $g))
  > WAT
  $ wax -i wat -f wax t.wat -o t.wax && wax -i wax -f wasm t.wax -o /dev/null --validate
