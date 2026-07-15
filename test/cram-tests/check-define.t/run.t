The `check` subcommand takes -D/--define, like `convert`: it specializes the
conditionals before validating. A full assignment validates one configuration; a
partial one leaves the rest for the path-sensitive check to explore.

  $ cat > m.wax <<'WAX'
  > #[if(debug)]
  > {
  >     const c: i32 = 1.5;
  > }
  > #[else]
  > {
  >     const c: i32 = 0;
  > }
  > WAX

With no -D, every feasible configuration is validated; the ill-typed `debug`
branch is reported (reachable only when `debug`):

  $ wax check m.wax
  Error: This instruction has type 'float' but is expected to have type 'i32'.
   ──➤  m.wax:3:20
  1 │ #[if(debug)]
  2 │ {
  3 │     const c: i32 = 1.5;
    ·                    ^^^
  4 │ }
  5 │ #[else]
  Hint: reachable when debug
  [128]

`-D debug=false` selects the well-typed else branch:

  $ wax check -D debug=false m.wax

`-D debug=true` selects the ill-typed branch, so the error is unconditional:

  $ wax check -D debug=true m.wax
  Error: This instruction has type 'float' but is expected to have type 'i32'.
   ──➤  m.wax:3:20
  1 │ #[if(debug)]
  2 │ {
  3 │     const c: i32 = 1.5;
    ·                    ^^^
  4 │ }
  5 │ #[else]
  [128]
