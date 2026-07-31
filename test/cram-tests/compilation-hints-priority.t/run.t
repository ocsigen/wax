The compilation-hints proposal's function-level section,
`metadata.code.compilation_priority`: how soon to compile a function and how hard
to optimize it. It is the one hint of the family that belongs to a function rather
than an instruction, so in Wax it is an ordinary field attribute rather than an
expression prefix, and in WAT an annotation inside `(func …)` after the type use —
the position that means the offset-0 entry the section keys it under.

`#[priority = n]` is what makes the entry exist; the optional optimization priority
is `#[optimization = n]`, or `#[run_once]` for the reserved value that says the
function is expected to run once, so optimizing it is wasted work:

  $ wax -i wax -f wat prio.wax
  (import "m" "ext" (func $ext (param $x i32) (result i32)))
  (import "m" "ext2" (func $ext2 (param $x i32) (result i32)))
  
  (func $init (export "init")
    (@metadata.code.compilation_priority (priority 1) (run_once))
    (nop)
  )
  
  (func $hot (export "hot") (param $x i32) (result i32)
    (@metadata.code.compilation_priority (priority 5) (optimization 10))
    (call $ext (local.get $x))
  )
  
  (func $warm (export "warm") (param $x i32) (result i32)
    (@metadata.code.compilation_priority (priority 2))
    (call $ext2 (local.get $x))
  )

All three survive a binary round trip. The section states absolute function
indices, so the two imports shift the base — a fixture with imports is the point:

  $ wax -i wax -f wasm prio.wax -o prio.wasm
  $ wax -i wasm -f wat prio.wasm | grep compilation_priority
    (@metadata.code.compilation_priority (priority 1) (run_once))
    (@metadata.code.compilation_priority (priority 5) (optimization 10))
    (@metadata.code.compilation_priority (priority 2))

Re-encoding the decompiled module reproduces the section byte for byte:

  $ wax -i wasm -f wat prio.wasm > back.wat
  $ wax -i wat -f wasm back.wat -o again.wasm
  $ cmp -s prio.wasm again.wasm && echo identical
  identical

And they come back as the attributes they were written with, `#[priority]` first:

  $ wax -i wasm -f wax prio.wasm | grep 'priority\|run_once\|optimization'
  #[priority = 1]
  #[run_once]
  #[priority = 5]
  #[optimization = 10]
  #[priority = 2]

The raw-byte payload is accepted too, and decodes to the structured form. Here
`"\03\7f"` is a compilation priority of 3 and the run-once optimization value, 127:

  $ wax -i wat -f wat raw.wat
  (func (export "f")
    (@metadata.code.compilation_priority (priority 3) (run_once))
    (nop)
  )

The section states an optimization priority only alongside a compilation one, so
either spelling of it needs `#[priority]` too — rejected rather than given a
compilation priority the author did not choose:

  $ wax check noprio.wax
  Error: The '#[optimization]' attribute needs a '#[priority = n]'.
   ──➤  noprio.wax:2:1
  1 │ #[export]
  2 │ #[optimization = 3]
    · ^^^^^^^^^^^^^^^^^^^
  3 │ fn f() { nop; }
  4 │ 
  [128]

A function states at most one optimization priority. The diagnostic is blamed at
the `#[optimization]` value: an attribute carries no span of its own and
`#[run_once]` has no value, so that is the one span available.

  $ wax check conflict.wax
  Error:
    A function states at most one optimization priority: '#[optimization = n]'
    or '#[run_once]', not both.
   ──➤  conflict.wax:3:1
  1 │ #[export]
  2 │ #[priority = 1]
  3 │ #[optimization = 3]
    · ^^^^^^^^^^^^^^^^^^^
  4 │ #[run_once]
    · ^^^^^^^^^^^ the other one here
  5 │ fn f() { nop; }
  6 │ 
  [128]

A priority needs a body to attach to, so it is allowed on a defined function only:
an imported one has no code-section entry to key an offset-0 hint in.

  $ wax check onimport.wax
  Error: The priority annotation is not allowed here.
   ──➤  onimport.wax:2:5
  1 │ import "m" {
  2 │     #[priority = 1]
    ·     ^^^^^^^^^^^^^^^
  3 │     fn ext();
  4 │ }
  [128]

A priority is stored as a ULEB, and both the compilation and the optimization
value are range-checked: a `NAT` token can be arbitrarily long, and an over-long
one used to reach a raw `int_of_string` and crash the whole pipeline with an
uncaught `Failure` — the same class as the non-finite frequency, found by the same
fuzzer.

  $ cat > huge.wat <<'WAT'
  > (module (func (export "f")
  >   (@metadata.code.compilation_priority (priority 99999999999999999999999))
  >   nop))
  > WAT
  $ wax check huge.wat 2>&1 | head -1
  Error: Constant 99999999999999999999999 is out of range.

  $ sed 's/(priority 99999999999999999999999)/(priority 1) (optimization 99999999999999999999999)/' huge.wat > huge2.wat
  $ wax check huge2.wat 2>&1 | head -1
  Error: Constant 99999999999999999999999 is out of range.

The Wax attribute is checked by the typer instead, so the value is rejected before
it reaches the lowering — which trusts its input, and whose own `int_of_string`
was the thing crashing. The boundary is the u32 the encoding can carry:

  $ cat > huge.wax <<'WAX'
  > fn g() {}
  > #[priority = 99999999999999999999999]
  > #[export]
  > fn f() { g(); }
  > WAX
  $ wax check huge.wax 2>&1 | head -1
  Error: The priority annotation expects an integer in the u32 range.

  $ sed 's/99999999999999999999999/4294967296/' huge.wax > over.wax
  $ wax check over.wax 2>&1 | head -1
  Error: The priority annotation expects an integer in the u32 range.

  $ sed 's/99999999999999999999999/4294967295/' huge.wax > max.wax
  $ wax check max.wax
