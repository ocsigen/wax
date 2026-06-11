Validation errors that previously carried a dummy location now point at the
offending construct or value.

A constant expression leaving an extra value on the stack points at that value:

  $ wax --validate global_extra.wat -o out.wat
  Error: Type mismatch: this value is left on the stack.
   ──➤  global_extra.wat:2:19
  1 │ (module
  2 │   (global $g i32 (i32.const 1) (i32.const 2)))
    ·                   ^^^^^^^^^^^
  3 │ 
  [128]

When several values are left, a caret lands on each of them:

  $ wax --validate global_extra_multi.wat -o out.wat
  Error: Type mismatch: these values are left on the stack.
   ──➤  global_extra_multi.wat:2:33
  1 │ (module
  2 │   (global $g i32 (i32.const 1) (i32.const 2) (i32.const 3)))
    ·                                 ^^^^^^^^^^^
    ·                   ^^^^^^^^^^^ 
  3 │ 
  [128]

A constant expression producing no value points at the global too:

  $ wax --validate global_empty.wat -o out.wat
  Error: Type mismatch: the stack is empty (a value is missing).
   ──➤  global_empty.wat:2:4
  1 │ (module
  2 │   (global $g i32))
    ·    ^^^^^^^^^^^^^^
  3 │ 
  [128]

A continuation type that does not wrap a function type points at the type
definition:

  $ wax --validate cont_not_func.wat -o out.wat
  Error: Type $s should be a function type.
   ──➤  cont_not_func.wat:3:4
  1 │ (module
  2 │   (type $s (struct))
  3 │   (type $c (cont $s)))
    ·    ^^^^^^^^^^^^^^^^^^
  4 │ 
  [128]

The wrapped type is named as the source wrote it, even when an identical type
($b here) shares its canonical index:

  $ wax --validate cont_not_func_dup.wat -o out.wat
  Error: Type $a should be a function type.
   ──➤  cont_not_func_dup.wat:4:4
  2 │   (type $a (struct))
  3 │   (type $b (struct))
  4 │   (type $c (cont $a)))
    ·    ^^^^^^^^^^^^^^^^^^
  5 │ 
  [128]

An invalid subtype declaration points at the offending type definition:

  $ wax --validate bad_subtype.wat -o out.wat
  Error: This type is not a valid subtype of its declared supertype.
   ──➤  bad_subtype.wat:3:4
  1 │ (module
  2 │   (type $a (sub (func (param i32))))
  3 │   (type $b (sub $a (func (param i64)))))
    ·    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  [128]
