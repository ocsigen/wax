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
