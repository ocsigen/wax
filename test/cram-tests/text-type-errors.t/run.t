A type-mismatch error now prints both the type an instruction expects and the
value found on the stack as the source wrote them — naming an indexed type by
its source reference ($name) rather than the interned canonical index, which is
opaque and can even differ from what the user typed when distinct source types
share a canonical index.

A ref.cast result feeding an instruction that wants an i32:

  $ wax --validate ref_cast.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type (ref $point)
   ──➤  ref_cast.wat:4:6
  2 │   (type $point (struct (field i32)))
  3 │   (func (param (ref any)) (result i32)
  4 │     (ref.cast (ref $point) (local.get 0))))
    ·      ^^^^^^^^^^^^^^^^^^^^^
  5 │ 
  [128]

A struct.new_default whose result does not match the declared result type:

  $ wax --validate struct_new.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref 1)
    but the stack has type (ref $point)
   ──➤  struct_new.wat:5:6
  3 │   (type $other (struct (field f64)))
  4 │   (func (result (ref $other))
  5 │     (struct.new_default $point)))
    ·      ^^^^^^^^^^^^^^^^^^^^^^^^^
  6 │ 
  [128]

A cont.new result feeding an instruction that wants an i32:

  $ wax --validate cont_new.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type (ref $ct)
   ──➤  cont_new.wat:6:6
  4 │     (type $ct (cont $ft)))
  5 │   (func (param (ref null $ft)) (result i32)
  6 │     (cont.new $ct (local.get 0))))
    ·      ^^^^^^^^^^^^
  7 │ 
  [128]

The expected type is named too, at the instructions that pop a reference to a
type the user named. A struct.get whose operand is not a reference:

  $ wax --validate struct_get.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref null $point)
    but the stack has type i32
   ──➤  struct_get.wat:4:27
  2 │   (type $point (struct (field i32)))
  3 │   (func (result i32)
  4 │     (struct.get $point 0 (i32.const 0))))
    ·                           ^^^^^^^^^^^
  5 │ 
  [128]

A call_ref whose callee operand is not a reference:

  $ wax --validate call_ref.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref null $ft)
    but the stack has type i32
   ──➤  call_ref.wat:4:20
  2 │   (type $ft (func (result i32)))
  3 │   (func (result i32)
  4 │     (call_ref $ft (i32.const 0))))
    ·                    ^^^^^^^^^^^
  5 │ 
  [128]
