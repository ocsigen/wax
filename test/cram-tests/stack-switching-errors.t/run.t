Stack-switching validation errors previously all shared the message "Type
mismatch in stack switching instruction." Each failure mode now explains what
is actually wrong and points at the offending instruction.

A cont.bind whose target continuation takes more parameters than the source:

  $ wax --validate cont_bind_arity.wat -o out.wat
  Error:
    Type mismatch in this stack switching instruction: the resulting
    continuation takes more parameters than the original one.
   ──➤  cont_bind_arity.wat:7:6
  5 │   (type $ct1 (cont $ft1))
  6 │   (func $f (param $k (ref null $ct0)) (result (ref $ct1))
  7 │     (cont.bind $ct0 $ct1 (local.get $k))))
    ·      ^^^^^^^^^^^^^^^^^^^
  8 │ 
  [128]

A cont.bind whose bound parameters do not match the target continuation:

  $ wax --validate cont_bind_type.wat -o out.wat
  Error:
    Type mismatch in this stack switching instruction: the bound parameters and
    results do not match between the two continuation types.
   ──➤  cont_bind_type.wat:7:6
  5 │   (type $ct1 (cont $ft1))
  6 │   (func $f (param $k (ref null $ct0)) (result (ref $ct1))
  7 │     (cont.bind $ct0 $ct1 (local.get $k))))
    ·      ^^^^^^^^^^^^^^^^^^^
  8 │ 
  [128]

A switch whose continuation does not end in a continuation parameter:

  $ wax --validate switch_not_cont.wat -o out.wat
  Error:
    Type mismatch in this stack switching instruction: the continuation's last
    parameter must itself be a continuation type.
   ──➤  switch_not_cont.wat:6:6
  4 │   (tag $e (result i32))
  5 │   (func $f (param $k (ref null $ct)) (result i32)
  6 │     (switch $ct $e (local.get $k))))
    ·      ^^^^^^^^^^^^^
  7 │ 
  [128]

A switch whose tag takes parameters:

  $ wax --validate switch_tag.wat -o out.wat
  Error:
    Type mismatch in this stack switching instruction: the 'switch' tag must
    take no parameters and its results must match the two continuation types.
    ──➤  switch_tag.wat:9:6
   7 │   (tag $e (param i32) (result i32))
   8 │   (func $sw (param $k (ref null $ct1)) (result i32)
   9 │     (switch $ct1 $e (local.get $k))))
     ·      ^^^^^^^^^^^^^^
  10 │ 
  [128]

A resume on-label handler with the wrong block type points at the label:

  $ wax --validate resume_handler.wat -o out.wat
  Error:
    Type mismatch in this stack switching instruction: this handler must take
    the tag's parameters followed by a continuation of the remaining result
    type.
   ──➤  resume_handler.wat:7:30
  5 │   (func $handle (param $k0 (ref null $ct)) (result i32)
  6 │     (block $h (result i32)
  7 │       (resume $ct (on $yield $h) (i32.const 1) (local.get $k0))
    ·                              ^^
  8 │       (return))
  9 │     (return)))
  [128]

A resume on-switch handler whose tag takes parameters:

  $ wax --validate resume_switch_tag.wat -o out.wat
  Error:
    Type mismatch in this stack switching instruction: the tag of a 'switch'
    handler must take no parameters.
    ──➤  resume_switch_tag.wat:8:6
   6 │   (func $f (type $sft) (param (ref null $sct)) (result i32) (i32.const 0))
   7 │   (func $onsw (param $k (ref null $sct)) (result i32)
   8 │     (resume $sct (on $swap switch) (local.get $k) (cont.new $sct (ref.func $f))))
     ·      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   9 │   (elem declare func $f))
  10 │ 
  [128]
