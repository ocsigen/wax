extern.convert_any over a typed ref.null decompiles to a double cast,
(null as &?t) as &?extern. The simplify pass drops a redundant cast of null only
down to a *bare* null (which re-checks to the context's type); it must not peel
the outer cast off a nested typed-null cast, which would change &?extern back to
the inner array type and produce a module that no longer type-checks.
Regression: found by the smith fuzzer.

  $ cat > t.wat <<'WAT'
  > (module
  >   (type $a (array i64))
  >   (global $g (mut externref) (ref.null extern))
  >   (func (export "f")
  >     ref.null $a
  >     extern.convert_any
  >     global.set $g))
  > WAT
  $ wax -i wat -f wax t.wat
  type a = [i64];
  let g: &?extern = null;
  #[export]
  fn f() {
      g = null as &?a as &?extern;
  }
  $ wax -i wat -f wax t.wat -o t.wax && wax -i wax -f wasm t.wax -o /dev/null --validate
