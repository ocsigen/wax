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

The type also rides on values read from declared locals, globals and tables. A
local.get of a reference local:

  $ wax --validate local_get.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type (ref $t)
   ──➤  local_get.wat:4:6
  2 │   (type $t (struct))
  3 │   (func (param $p (ref $t)) (result i32)
  4 │     (local.get $p)))
    ·      ^^^^^^^^^^^^
  5 │ 
  [128]

A global.set with the wrong value type names the global's declared type:

  $ wax --validate global_set.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref null $t)
    but the stack has type i32
   ──➤  global_set.wat:5:21
  3 │   (global $g (mut (ref null $t)) (ref.null $t))
  4 │   (func
  5 │     (global.set $g (i32.const 0))))
    ·                     ^^^^^^^^^^^
  6 │ 
  [128]

A br_on_cast whose operand is not a reference names the cast's source type:

  $ wax --validate br_on_cast.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref $t)
    but the stack has type i32
   ──➤  br_on_cast.wat:5:41
  3 │   (func (result i32)
  4 │     (block $b (result (ref $t))
  5 │       (br_on_cast $b (ref $t) (ref $t) (i32.const 0))
    ·                                         ^^^^^^^^^^^
  6 │       (unreachable))
  7 │     (drop)
  [128]

The source type even reaches *components* of a named type: a struct.get names
the field's declared type, recovered from the stored source definition:

  $ wax --validate struct_field.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type (ref $inner)
   ──➤  struct_field.wat:5:6
  3 │   (type $outer (struct (field (ref $inner))))
  4 │   (func (param (ref $outer)) (result i32)
  5 │     (struct.get $outer 0 (local.get 0))))
    ·      ^^^^^^^^^^^^^^^^^^^
  6 │ 
  [128]

An array.set names the element's declared type:

  $ wax --validate array_elem.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref $elem)
    but the stack has type i32
   ──➤  array_elem.wat:5:50
  3 │   (type $arr (array (mut (ref $elem))))
  4 │   (func (param (ref $arr))
  5 │     (array.set $arr (local.get 0) (i32.const 0) (i32.const 1))))
    ·                                                  ^^^^^^^^^^^
  6 │ 
  [128]

Function arguments and results carry their declared source types too — even
for the inline (implicit) function type of a definition. A wrong call argument:

  $ wax --validate call_arg.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref $t)
    but the stack has type i32
   ──➤  call_arg.wat:5:15
  3 │   (func $g (param (ref $t)))
  4 │   (func
  5 │     (call $g (i32.const 0))))
    ·               ^^^^^^^^^^^
  6 │ 
  [128]

A call result that does not match what the caller declares:

  $ wax --validate call_result.wat -o out.wat
  Error: Type mismatch: expecting type i32 but got type (ref $t).
   ──➤  call_result.wat:4:4
  2 │   (type $t (struct))
  3 │   (func $g (result (ref $t)) (unreachable))
  4 │   (func (result i32)
    ·    ^^^^^^^^^^^^^^^^^^
  5 │     (call $g)))
    · ^^^^^^^^^^^^^^
  6 │ 
  [128]

The argument type comes from the called function's own declaration, so a call
names it correctly even when another structurally-identical type ($b here)
shares its canonical index — $f1 is named with $a, not $b:

  $ wax --validate call_shared_index.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref $a)
    but the stack has type i32
   ──➤  call_shared_index.wat:7:16
  5 │   (func $f2 (param (ref $b)))
  6 │   (func
  7 │     (call $f1 (i32.const 0))))
    ·                ^^^^^^^^^^^
  8 │ 
  [128]

Components resolve through the use-site reference too, so a struct.get on $a
names its field's type ($x) even though the identical $b (whose field is the
identical $y) shares both canonical indices:

  $ wax --validate struct_field_shared_index.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type (ref $x)
   ──➤  struct_field_shared_index.wat:7:6
  5 │   (type $b (struct (field (ref $y))))
  6 │   (func (param (ref $a)) (result i32)
  7 │     (struct.get $a 0 (local.get 0))))
    ·      ^^^^^^^^^^^^^^^
  8 │ 
  [128]

A block result type is named from the block's declared type when the body
leaves the wrong value:

  $ wax --validate block_result.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref $t)
    but the stack has type i32
   ──➤  block_result.wat:5:8
  3 │   (func
  4 │     (block (result (ref $t))
  5 │       (i32.const 0))
    ·        ^^^^^^^^^^^
  6 │     (drop)))
  7 │ 
  [128]

A thrown exception payload is named from the tag's declared parameter type:

  $ wax --validate throw_payload.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref $t)
    but the stack has type i32
   ──➤  throw_payload.wat:5:16
  3 │   (tag $e (param (ref $t)))
  4 │   (func
  5 │     (throw $e (i32.const 0))))
    ·                ^^^^^^^^^^^
  6 │ 
  [128]

Stack-switching instructions name their continuation operand. A resume with a
non-continuation operand:

  $ wax --validate resume_cont.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref null $ct)
    but the stack has type i32
   ──➤  resume_cont.wat:4:32
  2 │   (rec (type $ft (func (param i32) (result i32))) (type $ct (cont $ft)))
  3 │   (func (result i32)
  4 │     (resume $ct (i32.const 0) (i32.const 1))))
    ·                                ^^^^^^^^^^^
  5 │ 
  [128]

And a suspend names the tag's declared payload type:

  $ wax --validate suspend_payload.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref $t)
    but the stack has type i32
   ──➤  suspend_payload.wat:5:18
  3 │   (tag $e (param (ref $t)) (result i32))
  4 │   (func (result i32)
  5 │     (suspend $e (i32.const 0))))
    ·                  ^^^^^^^^^^^
  6 │ 
  [128]

A value popped and re-pushed keeps its source type: ref.as_non_null on a
nullable reference yields the non-null form named as the source wrote it:

  $ wax --validate ref_as_non_null.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type (ref $t)
   ──➤  ref_as_non_null.wat:4:6
  2 │   (type $t (struct))
  3 │   (func (param (ref null $t)) (result i32)
  4 │     (ref.as_non_null (local.get 0))))
    ·      ^^^^^^^^^^^^^^^
  5 │ 
  [128]

A branch names its target's declared type. A br carrying the wrong value to a
labelled block:

  $ wax --validate br_target.wat -o out.wat
  Error: Type mismatch: this instruction expects type (ref $t)
    but the stack has type i32
   ──➤  br_target.wat:5:15
  3 │   (func (result i32)
  4 │     (block $b (result (ref $t))
  5 │       (br $b (i32.const 0)))
    ·               ^^^^^^^^^^^
  6 │     (drop)
  7 │     (i32.const 0)))
  [128]

And a br_on_cast whose cast type does not match the branch target names both —
the target ($c) and the value it carries ($b):

  $ wax --validate br_on_cast_target.wat -o out.wat
  Error: Type mismatch: expecting type (ref $c) but got type (ref $b).
   ──➤  br_on_cast_target.wat:7:8
  5 │   (func (param (ref $a)) (result i32)
  6 │     (block $l (result (ref $c))
  7 │       (br_on_cast $l (ref $a) (ref $b) (local.get 0))
    ·        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │       (unreachable))
  9 │     (drop)
  [128]

A tail call's result list is named from the callee's declared results:

  $ wax --validate return_call_result.wat -o out.wat
  Error: Type mismatch: this tail call provides type (ref $t) but type 
    i32 was expected.
   ──➤  return_call_result.wat:5:6
  3 │   (func $g (result (ref $t)) (unreachable))
  4 │   (func (result i32)
  5 │     (return_call $g)))
    ·      ^^^^^^^^^^^^^^
  6 │ 
  [128]

An exception handler names the tag's payload from its declared type:

  $ wax --validate catch_handler.wat -o out.wat
  Error: Type mismatch: this exception handler provides type (ref $t) but type
    i32 was expected.
   ──➤  catch_handler.wat:6:8
  4 │   (func
  5 │     (block $b (result i32)
  6 │       (try_table (catch $e $b))
    ·        ^^^^^^^^^^^^^^^^^^^^^^^
  7 │       (return))
  8 │     (drop)))
  [128]

A call_indirect on a non-function table names the table's declared element type:

  $ wax --validate table_element.wat -o out.wat
  Error: Type mismatch: the table $tb should contain functions but its elements
    have type (ref null $t).
   ──➤  table_element.wat:6:6
  4 │   (table $tb 1 (ref null $t))
  5 │   (func
  6 │     (call_indirect $tb (type $ft) (i32.const 0))))
    ·      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  7 │ 
  [128]

An element segment whose type is not a subtype of the table's names both:

  $ wax --validate elem_segment.wat -o out.wat
  Error: Type mismatch: the element segment has type (ref null $t),
    which is not a subtype of the table element type (ref null func).
   ──➤  elem_segment.wat:4:4
  2 │   (type $t (struct))
  3 │   (table $tb 1 funcref)
  4 │   (elem (table $tb) (i32.const 0) (ref null $t)))
    ·    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  5 │ 
  [128]

A table.copy between tables with mismatched element types names both:

  $ wax --validate table_copy.wat -o out.wat
  Error: Type mismatch: expecting type (ref null $a) but got type
    (ref null $b).
   ──➤  table_copy.wat:7:6
  5 │   (table $tb 1 (ref null $b))
  6 │   (func
  7 │     (table.copy $ta $tb (i32.const 0) (i32.const 0) (i32.const 0))))
    ·      ^^^^^^^^^^^^^^^^^^
  8 │ 
  [128]

A parameter declared only through a referenced function type still names its
source type, taken from that type's definition:

  $ wax --validate param_from_type.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type (ref $t)
   ──➤  param_from_type.wat:5:21
  3 │   (type $ft (func (param (ref $t))))
  4 │   (func (type $ft)
  5 │     (drop (i32.add (local.get 0) (i32.const 1)))))
    ·                     ^^^^^^^^^^^
  6 │ 
  [128]
