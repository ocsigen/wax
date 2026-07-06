A branch hint wraps the whole branch instruction, so a `ref.func` nested inside
a hinted `if` (or `br_on_*`) must still be found and declared — otherwise the
emitted binary fails strict reference validation. Compiling with `-s` succeeds
and the `(elem declare func $target)` is present:

  $ wax m.wat -f wasm -s -o m.wasm && wax m.wasm -f wat
  (type (func))
  (type (func (param i32)))
  (func $target)
  (func (param i32)
    local.get 0
    (@metadata.code.branch_hint "\01")
    if (type 0)
      ref.func $target
      drop
    end
  )
  (elem declare func $target)
