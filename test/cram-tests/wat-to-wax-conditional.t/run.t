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

Numeric references to module fields are refused when the module has a
conditional annotation, since a field's index depends on which branch is taken.

  $ wax numref.wat -o out2.wax
  wax: internal error, uncaught exception:
       Failure("Numeric references to module fields are not supported in a module with conditional annotations (index 0); use a symbolic $name.")
       
  [125]
