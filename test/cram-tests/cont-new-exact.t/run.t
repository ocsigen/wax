`cont.new` and `cont.bind` allocate a fresh continuation of exactly the named
type, so their result is an *exact* reference (like `struct.new`/`array.new`).
The Wasm validator tracks this internally, so a `resume` applied directly to a
`cont.new` result — whose static heap type is now `(exact $ct)` — still resolves
the continuation's function type:

  $ wax check resume-on-new.wat

  $ cat resume-on-new.wat
  (module
    (type $ft (func (param i32) (result i32)))
    (type $ct (cont $ft))
    (func $g (param i32) (result i32) (local.get 0))
    (func (export "f") (param i32) (result i32)
      (resume $ct (local.get 0) (cont.new $ct (ref.func $g))))
    (elem declare func $g))

With custom-descriptors, the exactness is observable: a `cont.new` / `cont.bind`
result satisfies a `(ref (exact $ct))` requirement.

  $ wax check -X custom-descriptors exact-result.wat

  $ cat exact-result.wat
  (module
    (type $ft (func (param i32) (result i32)))
    (type $ct (cont $ft))
    (func $g (param i32) (result i32) (local.get 0))
    (func (export "f") (result (ref (exact $ct)))
      (cont.new $ct (ref.func $g)))
    (func (export "b") (param $c (ref $ct)) (result (ref (exact $ct)))
      (cont.bind $ct $ct (local.get $c)))
    (elem declare func $g))

Diagnostics render the source type with the same exactness as the internal
type. Under custom-descriptors the `cont.new` result is reported exact:

  $ wax check -X custom-descriptors bad-source.wat
  Error: Type mismatch: this produces a value of type (ref (exact $ct)),
    but type i32 is expected.
   ──➤  bad-source.wat:6:6
  4 │   (func $g)
  5 │   (func (export "f") (result i32)
  6 │     (cont.new $ct (ref.func $g)))
    ·      ^^^^^^^^^^^^
  7 │   (elem declare func $g))
  8 │ 
  [128]

Without the proposal exact reference types are not expressible, so the same
diagnostic falls back to the plain reference:

  $ wax check bad-source.wat
  Error: Type mismatch: this produces a value of type (ref $ct), but type 
    i32 is expected.
   ──➤  bad-source.wat:6:6
  4 │   (func $g)
  5 │   (func (export "f") (result i32)
  6 │     (cont.new $ct (ref.func $g)))
    ·      ^^^^^^^^^^^^
  7 │   (elem declare func $g))
  8 │ 
  [128]
