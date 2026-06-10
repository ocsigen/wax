Argument lists checked against parameter lists (tail calls, exception
handlers) report the two type lists directly, rather than leaking the
internal "values left on the stack" representation.

A tail call whose callee returns more results than the enclosing function:

  $ wax --validate return_call_arity.wat -o out.wat
  Error: Type mismatch: this tail call provides type [i32 i32] but type 
    [i32] was expected.
   ──➤  return_call_arity.wat:4:6
  2 │   (func $callee (result i32 i32) (i32.const 1) (i32.const 2))
  3 │   (func $caller (result i32)
  4 │     (return_call $callee)))
    ·      ^^^^^^^^^^^^^^^^^^^
  5 │ 
  [128]

A tail call whose result type does not match the enclosing function:

  $ wax --validate return_call_type.wat -o out.wat
  Error: Type mismatch: this tail call provides type f64 but type i32
    was expected.
   ──➤  return_call_type.wat:4:6
  2 │   (func $callee (result f64) (f64.const 1))
  3 │   (func $caller (result i32)
  4 │     (return_call $callee)))
    ·      ^^^^^^^^^^^^^^^^^^^
  5 │ 
  [128]

An exception handler whose tag payload does not match the branch target:

  $ wax --validate catch_type.wat -o out.wat
  Error: Type mismatch: this exception handler provides type i32 but type 
    f64 was expected.
   ──➤  catch_type.wat:5:8
  3 │   (func $f
  4 │     (block $b (result f64)
  5 │       (try_table (catch $e $b))
    ·        ^^^^^^^^^^^^^^^^^^^^^^^
  6 │       (return))
  7 │     (drop)))
  [128]

A bare catch_all transfers no value, so the branch target must take none:

  $ wax --validate catch_all_arity.wat -o out.wat
  Error: Type mismatch: this exception handler provides type [] but type 
    [i32] was expected.
   ──➤  catch_all_arity.wat:5:8
  3 │   (func $f
  4 │     (block $b (result i32)
  5 │       (try_table (catch_all $b))
    ·        ^^^^^^^^^^^^^^^^^^^^^^^^
  6 │       (return))
  7 │     (drop)))
  [128]
