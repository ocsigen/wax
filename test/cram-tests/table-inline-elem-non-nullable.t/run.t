An inline element list lowers to an active element segment, which fills the
table at instantiation. The table itself is still default-initialized, so a
non-nullable element type has no value to start from and the form is rejected,
exactly as a table with no initializer at all is:

  $ cat > non-nullable.wat <<'WAT'
  > (module
  >   (func $f)
  >   (table $t (ref func) (elem $f))
  > )
  > WAT
  $ wax check non-nullable.wat
  Error: Type mismatch: the type of the elements of this table must be nullable.
   ──➤  non-nullable.wat:3:4
  1 │ (module
  2 │   (func $f)
  3 │   (table $t (ref func) (elem $f))
    ·    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ )
  5 │ 
  [128]

Accepting it would emit a table whose element type is not defaultable and which
carries no initializer, which both the reference interpreter and wasm-tools
reject ("non-defaultable element type").

The same table without the inline list is rejected the same way:

  $ cat > bare.wat <<'WAT'
  > (module
  >   (table $t 1 1 (ref func))
  > )
  > WAT
  $ wax check bare.wat
  Error: Type mismatch: the type of the elements of this table must be nullable.
   ──➤  bare.wat:2:4
  1 │ (module
  2 │   (table $t 1 1 (ref func))
    ·    ^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ )
  4 │ 
  [128]

A nullable element type is fine, and keeps the segment's own type: the funcidx
spelling of the inline list denotes the table's reftype, not `(ref func)`, so a
table of a concrete function type accepts it too.

  $ cat > ok.wat <<'WAT'
  > (module
  >   (type $t1 (sub (func)))
  >   (type $t2 (sub $t1 (func)))
  >   (func $f2 (type $t2))
  >   (table $t funcref (elem $f2))
  >   (table $u (ref null $t2) (elem $f2))
  >   (func (export "go") (result funcref) (table.get $t (i32.const 0)))
  >   (func (export "go2") (result (ref null $t2)) (table.get $u (i32.const 0)))
  > )
  > WAT
  $ wax check ok.wat && echo OK
  OK
  $ wax ok.wat -o ok.wasm
  $ wax ok.wasm -f wat | grep elem
  (elem (table $t) (offset i32.const 0) funcref (item ref.func $f2))
  (elem (table $u) (offset i32.const 0) (ref null $t2) (item ref.func $f2))
