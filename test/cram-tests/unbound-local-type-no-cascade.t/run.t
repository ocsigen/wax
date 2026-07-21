A local declared with a type that does not resolve (here the unbound type index
`$missing`) is reported once, at the declaration. The local is then poisoned: a
`local.get` yields the bottom reference and a `local.set` accepts any operand,
so its uses (`local.set $r` from a `ref.func`, `local.get $r` as the `funcref`
result) do not cascade a second, spurious type mismatch against the recovery
dummy type.

  $ wax check -f wat m.wat
  Error: Unknown type: index '$missing' is not bound.
   ──➤  m.wat:5:25
  3 │   (func $g (type $ft) (local.get 0))
  4 │   (func (export "f") (result funcref)
  5 │     (local $r (ref null $missing))
    ·                         ^^^^^^^^
  6 │     (ref.func $g)
  7 │     (local.set $r)
  [128]
