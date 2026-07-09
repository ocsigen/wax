A `#[export]` attribute may carry an `if <cond>` guard, making just that export
conditional independently of the field's own reachability. This is the Wax form
of a standalone `(export …)` that sits inside an `(@if …)` block but names an
entity defined outside it.

A Wasm function defined unconditionally but re-exported under a second name only
in one conditional branch decompiles to a guarded `#[export]`:

  $ wax reexport.wat -f wax
  #[export]
  #[export = "fmt", if not(portable)]
  fn fmt32(v: &eq) -> &eq {
      v;
  }
  #[if(portable)]
  {
      import "m"
      #[export = "fmt"]
      fn fmt64(&eq) -> &eq;
  }

The guard lowers back to a standalone conditional export, so the round-trip is
faithful:

  $ wax reexport.wat -f wax | wax -i wax -f wat
  (func $fmt32 (export "fmt32") (param $v (ref eq)) (result (ref eq))
    (local.get $v)
  )
  (@if (not $portable) (@then (export "fmt" (func $fmt32))))
  (@if $portable
    (@then
      (func $fmt64 (export "fmt") (import "m" "fmt64")
        (param (ref eq)) (result (ref eq))))
  )

The guard is simplified against the conditionals the target already sits inside,
so a redundant conjunct is dropped rather than re-accumulated on each round-trip:

  $ wax nested.wat -f wax
  #[if(a)]
  {
      #[export]
      #[export = "g", if b]
      fn f(v: &eq) -> &eq {
          v;
      }
  }
  $ wax nested.wat -f wax | wax -i wax -f wat | wax -i wat -f wax
  #[if(a)]
  {
      #[export]
      #[export = "g", if b]
      fn f(v: &eq) -> &eq {
          v;
      }
  }

Guarded exports of the same name in mutually exclusive configurations do not
clash:

  $ wax check guarded.wax

but a guarded export overlapping an unconditional one does:

  $ wax check dup.wax
  Error: There is already an export of name "e".
   ──➤  dup.wax:3:12
  1 │ #[export = "e", if portable]
  2 │ fn a(v: &eq) -> &eq { v; }
  3 │ #[export = "e"]
    ·            ^^^
  4 │ fn b(v: &eq) -> &eq { v; }
  5 │ 
  [128]

Defining the guard variable resolves it: the export is kept when the guard holds
and dropped otherwise.

  $ wax guarded.wax -f wax -D portable=true
  #[export = "e"]
  fn a(v: &eq) -> &eq {
      v;
  }
  fn b(v: &eq) -> &eq {
      v;
  }
  $ wax guarded.wax -f wax -D portable=false
  fn a(v: &eq) -> &eq {
      v;
  }
  #[export = "e"]
  fn b(v: &eq) -> &eq {
      v;
  }

A `start` is folded onto its function the same way, so a `(start …)` inside an
`(@if …)` on a function defined outside it becomes a guarded `#[start]` (rather
than being silently dropped), and round-trips faithfully:

  $ wax cstart.wat -f wax
  #[start, if debug]
  fn init() {}
  $ wax cstart.wat -f wax | wax -i wax -f wat
  (func $init)
  (@if $debug (@then (start $init)))

A guard is only meaningful on an export or start, not on other attributes:

  $ wax check badguard.wax
  Error:
    A conditional guard is only allowed on an export or start annotation, not on import.
   ──➤  badguard.wax:2:21
  1 │ import "m" {
  2 │     #[import = "n", if debug]
    ·                     ^^
  3 │     fn f(&eq) -> &eq;
  4 │ }
  [128]
