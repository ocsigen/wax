A struct.new_default (or struct.new / array.new* / string) written with an
explicit type index must compile even when its inferred reference type is an
abstract heap type (e.g. the operand of a br_on_cast_fail in unreachable code,
typed at the bottom &none). The type index is taken from what was written; the
fallback that recovers it from the (here abstract) expression type must not be
evaluated when an index is present. It previously crashed with an assertion
failure in to_wasm. Regression: found by the smith fuzzer.

  $ cat > t.wat <<'WAT'
  > (module
  >   (type $t (struct (field i32)))
  >   (func (export "f") (result (ref none))
  >     block $l (result structref)
  >       struct.new_default $t
  >       br_on_cast_fail $l structref (ref none)
  >       return
  >     end
  >     unreachable))
  > WAT
  $ wax -i wat -f wax t.wat -o t.wax && wax -i wax -f wasm t.wax -o /dev/null --validate
