br_on_null on a bare, floating null (heap type not pinned, e.g. in unreachable
code) is accepted: the branch is always taken and the non-null fall-through has
the bottom reference type &none. It previously failed to recompile with "a
reference type is expected here". Regression: found by the smith fuzzer.

  $ cat > bon.wat <<'WAT'
  > (module
  >   (func (export "f")
  >     block $l
  >       ref.null none
  >       br_on_null $l
  >       drop
  >     end))
  > WAT
  $ wax -i wat -f wax bon.wat | grep -c br_on_null
  1
  $ wax -i wat -f wax bon.wat -o bon.wax && wax -i wax -f wasm bon.wax -o /dev/null --validate
