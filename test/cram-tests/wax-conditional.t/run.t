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

Conversion to WAT is not yet supported for conditionals.

  $ wax cond.wax -o out.wat
  wax: internal error, uncaught exception:
       Failure("Wax conditional annotations are not yet supported when converting to WAT.")
       
  [125]
