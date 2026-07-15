On a polymorphic (unreachable) stack, a reference-eliminating instruction does
not leave the stack fully unknown: it yields the bottom reference type
[(ref bot)]. That type is a subtype of every reference type but of no numeric
type, so a numeric use of the result is still rejected — the validator no longer
loses track of "this is a reference, just to an unknown heap type".

ref.as_non_null produces a reference, so feeding its result to i32.add fails:

  $ wax --validate as_non_null_num.wat -o out.wat
  Error:
    Type mismatch: this produces a value of type '(ref bot)', but type 'i32' is
    expected.
   ──➤  as_non_null_num.wat:4:5
  2 │   (func
  3 │     unreachable
  4 │     ref.as_non_null
    ·     ^^^^^^^^^^^^^^^
  5 │     i32.add
    ·     ^^^^^^^ expected here
  6 │     drop))
  7 │ 
  [128]

The value falling through br_on_null is likewise a reference:

  $ wax --validate br_on_null_num.wat -o out.wat
  Error:
    Type mismatch: this produces a value of type '(ref bot)', but type 'i32' is
    expected.
   ──➤  br_on_null_num.wat:5:7
  3 │     (block
  4 │       unreachable
  5 │       br_on_null 0
    ·       ^^^^^^^^^^^^
  6 │       i32.add
    ·       ^^^^^^^ expected here
  7 │       drop)))
  8 │ 
  [128]

ref.is_null consumes the bottom reference and yields i32, so a float use fails:

  $ wax --validate ref_is_null_num.wat -o out.wat
  Error:
    Type mismatch: this produces a value of type 'i32', but type 'f64' is
    expected.
   ──➤  ref_is_null_num.wat:4:5
  2 │   (func
  3 │     unreachable
  4 │     ref.is_null
    ·     ^^^^^^^^^^^
  5 │     f64.add
    ·     ^^^^^^^ expected here
  6 │     drop))
  7 │ 
  [128]

The bottom reference satisfies any reference type, so a non-null (ref any)
result is accepted:

  $ wax --validate as_non_null_ok.wat -o out.wat -f wat
