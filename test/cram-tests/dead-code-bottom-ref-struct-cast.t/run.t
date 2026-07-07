Regression (differential-validation fuzzer, diff-558). A `ref.cast` from a bottom
reference to a concrete struct/array type is load-bearing even though the target
is in the `any` hierarchy: Wasm's `struct.get` carries its type index, but Wax's
`.f` field access recovers the struct type from the receiver, so dropping the cast
leaves the field access with a bottom `&none` receiver and no type to resolve
against. `simplify` treated any `any`-hierarchy target as droppable and removed
it, so the decompiled module was accepted by `wax check` but its re-emitted wasm
failed validation ("Expected struct type"). The cast is now kept:

  $ cat > m.wat <<'WAT'
  > (module (type $s (struct (field i32)))
  >   (func (export "f") (result i32)
  >     block $l (result anyref)
  >       unreachable
  >       br_on_cast $l anyref nullref
  >       ref.cast (ref $s)
  >       struct.get $s 0
  >       drop
  >       ref.null any
  >     end
  >     drop
  >     i32.const 0))
  > WAT

  $ wax -i wat m.wat -f wax
  type s = { f: i32 };
  #[export]
  fn f() -> i32 {
      _ =
          'l: do {
              unreachable;
              _ = ((br_on_cast 'l &?none _) as &s).f;
              null;
          };
      0;
  }

  $ wax -i wat m.wat -f wax -o t.wax && wax -i wax t.wax -f wasm -o /dev/null --validate
