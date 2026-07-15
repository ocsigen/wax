Syntactic well-formedness checks (duplicate identifiers, inline type
annotations that disagree with the type they name, duplicate locals) now run as
part of the main validation, so the CLI enforces them.

A duplicate function identifier:

  $ wax --validate dup_function.wat -o out.wat
  Error: The function index '$f' is already bound.
   ──➤  dup_function.wat:3:9
  1 │ (module
  2 │   (func $f)
  3 │   (func $f))
    ·         ^^
  4 │ 
  [128]

An inline type annotation that disagrees with the named type:

  $ wax --validate inline_mismatch.wat -o out.wat
  Error: The inline function type does not match the type definition.
   ──➤  inline_mismatch.wat:3:15
  1 │ (module
  2 │   (type $t (func (param i32)))
  3 │   (func (type $t) (param i64)))
    ·               ^^
  4 │ 
  [128]

A duplicate local name:

  $ wax --validate dup_local.wat -o out.wat
  Error: The local '$x' is already defined.
   ──➤  dup_local.wat:2:31
  1 │ (module
  2 │   (func (local $x i32) (local $x i32)))
    ·                               ^^
  3 │ 
  [128]

These checks resolve type references through the same context as the rest of
validation, so a self-referential type validates cleanly (it would spuriously
fail if the check rebuilt its own type table):

  $ wax --validate recursive_ok.wat -o out.wat -f wat
