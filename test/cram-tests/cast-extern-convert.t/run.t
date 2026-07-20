The `any` <-> `extern` conversion (`extern.convert_any` / `any.convert_extern`,
spelled `as &extern` / `as &any`) is a total, never-trapping conversion, not a
`ref.cast`. The `cast-always-fails` lint must not fire on it even though the
operand and target sit in different reference hierarchies — only a genuine
`ref.cast` between unrelated types always traps.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the group:

  $ wax check -W correctness=warning convert.wax
  Warning: This cast always traps: the value can never have this type.
   ──➤  convert.wax:7:36
  5 │ 
  6 │ #[export = "always_fails"]
  7 │ fn always_fails(a: &s) -> &array { a as &array; }
    ·                                    ^^^^^^^^^^^
  8 │ 
