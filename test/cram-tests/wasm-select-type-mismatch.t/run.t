The two branches of an untyped `select` must have the same type. When they
don't, the validator points a caret at each branch value, labelled with its
type, rather than only at the `select` keyword:

  $ wax check sel.wat
  Error: Type mismatch: both branches of a select should have the same type.
   ──➤  sel.wat:3:12
  1 │ (module
  2 │   (func (param i32)
  3 │     (drop (select (i32.const 1) (i64.const 2) (local.get 0)))))
    ·            ^^^^^^
    ·                                  ^^^^^^^^^^^ 'i64'
    ·                    ^^^^^^^^^^^ 'i32'
  4 │ 
  [128]
