Conditional annotations in Wax (`#[if(...)]` / `#[else]`) parse, type-check, and
round-trip. Versions are integer tuples; conditions combine with all/any/not.

  $ wax cond.wax -o out.wax && cat out.wax
  #[if(ocaml_version >= (5, 1, 0))]
  const caml_marshal_header_size: i32 = 16;
  #[else]
  const caml_marshal_header_size: i32 = 20;
  
  #[if(feature = "gc")]
  fn gc_init() {}
  
  #[if(all(debug, not(target = "wasm32")))]
  { const debug_enabled: i32 = 1; fn debug_log(msg: i32) {} }

The output round-trips to itself.

  $ wax out.wax -o out2.wax && diff out.wax out2.wax

Type-checking explores configurations: the same name defined in #[if] and
#[else] is accepted, because the branches are mutually exclusive.

  $ wax --validate cond.wax -o checked.wax

An error confined to one branch is reported once, with the assumption under
which it is reachable.

  $ wax --validate bad.wax -o checked_bad.wax
  Error: This instruction has type float but is expected to have type i32.
   ──➤  bad.wax:4:16
  2 │ const x: i32 = 1;
  3 │ #[else]
  4 │ const x: i32 = nan;
    ·                ^^^
  5 │ 
  Hint: reachable when not debug
  [128]

Conversion to WAT produces `(@if …)` module-field annotations.

  $ wax cond.wax -o out.wat && cat out.wat
  (@if (>= $ocaml_version (5 1 0))
    (@then (global $caml_marshal_header_size i32 (i32.const 16)))
    (@else (global $caml_marshal_header_size i32 (i32.const 20)))
  )
  
  (@if (= $feature "gc") (@then (func $gc_init)))
  
  (@if (and $debug (not (= $target "wasm32")))
    (@then
      (global $debug_enabled i32 (i32.const 1))
      (func $debug_log (param $msg i32)))
  )

A name (here a function) declared with a different signature in each branch is
type-checked per configuration, so each branch's calls are checked against that
branch's signature. The typed module is rebuilt by stitching the per-branch
typings, so conversion to WAT keeps each branch's own signature and call.

  $ wax --validate sigs.wax -o checked_sigs.wax
  $ wax sigs.wax -o sigs.wat && cat sigs.wat
  (@if $wasi
    (@then
      (import "a" "g" (func $g (param i32 i32) (result i32)))
      (func $h (result i32) (call $g (i32.const 1) (i32.const 2))))
    (@else
      (import "b" "g" (func $g (param i32) (result i32)))
      (func $h (result i32) (call $g (i32.const 1))))
  )

Conversion to the WASM binary is still unsupported (binary cannot represent
conditionals).

  $ wax cond.wax -o out.wasm
  Error:
    Conditional annotations cannot be emitted to the WebAssembly binary format.
   ──➤  cond.wax:1:1
  1 │ #[if(ocaml_version >= (5, 1, 0))]
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ const caml_marshal_header_size: i32 = 16;
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ #[else]
    · ^^^^^^^^
  4 │ const caml_marshal_header_size: i32 = 20;
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  5 │ 
  6 │ #[if(feature = "gc")]
  Hint:
    Resolve the conditionals with -D/--define, or convert to a text format (wat or wax).
  [128]

