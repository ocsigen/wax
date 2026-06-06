A module-level conditional annotation in WAT converts to a Wax `#[if]`/`#[else]`.
A field with the same `$id` in both branches gets the same Wax name, so symbolic
references stay coherent.

  $ wax cond.wat -o out.wax && cat out.wax
  #[if(ocaml_version >= (5, 1, 0))]
  const size: i32 = 16;
  #[else]
  const size: i32 = 20;
  fn get() -> i32 { size; }

The produced Wax type-checks (the shared name is not a duplicate-definition
error, because the branches are mutually exclusive):

  $ wax --validate cond.wat -o checked.wax

Branches with different import sets (and a shared `$id`) keep each Wax name
attached to its own import; a sibling conditional on the negated condition does
not produce an infeasible configuration, so the result type-checks.

  $ wax deps.wat -o deps.wax && cat deps.wax
  #[if(wasi)]
  {
      #[import = ("a", "x")]
      fn x() -> i32;
      #[import = ("a", "g")]
      fn g() -> i32;
  }
  #[else]
  {
      #[import = ("b", "y")]
      fn y() -> i32;
      #[import = ("b", "g")]
      fn g() -> i32;
      #[import = ("b", "z")]
      fn z() -> i32;
  }
  #[if(not(wasi))]
  fn h() -> i32 { g(); }
  fn f() -> i32 { g(); }
  $ wax --validate deps.wat -o checked_deps.wax

Numeric references to module fields are refused when the module has a
conditional annotation, since a field's index depends on which branch is taken.

  $ wax numref.wat -o out2.wax
  wax: internal error, uncaught exception:
       Failure("Numeric references to module fields are not supported in a module with conditional annotations (index 0); use a symbolic $name.")
       
  [125]


A name declared with different arities in mutually-exclusive branches, but
referenced where the branch is undetermined (here `$g` from the unconditional
`$h`), has no single Wax conversion and is reported (it still validates as WAT):

  $ wax --validate ambig-arity.wat -f wat -o /dev/null
  $ wax ambig-arity.wat -o ambig.wax
  Error:
    Function g is declared with different arities in mutually-exclusive conditional branches but referenced where the branch is undetermined; this cannot be converted to Wax.
    ──➤  ambig-arity.wat:11:26
   9 │     (@else (import "m" "g" (func $g (param i32) (result i32)))))
  10 │   (func $h (result (ref $t))
  11 │     (struct.new $t (call $g (i32.const 1)))))
     ·                          ^^
  12 │ 
  [128]

