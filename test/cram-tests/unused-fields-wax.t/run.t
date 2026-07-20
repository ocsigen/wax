The `unused-field` warning fires on Wax source too: a module-defined function or
global that is never called, read, exported, or used as the start function is
reported by the type checker, mirroring the validator on WebAssembly input (see
`unused-fields-wat.t`). A function is reported the same way a global is — its own
definition site does not count as a use, so an unreferenced `fn` is flagged
unless its name starts with `_`.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the `unused`
group explicitly:

  $ wax check -W unused=warning unused.wax
  Warning [unused-field]: The global 'unused' is never used.
   ──➤  unused.wax:2:5
  1 │ let used: i32 = 1;
  2 │ let unused: i32 = 2;
    ·     ^^^^^^
  3 │ let _ignored: i32 = 3;
  4 │ #[export = "g"]
  Warning [unused-field]: The function 'unused_fn' is never used.
    ──➤  unused.wax:8:4
   6 │ 
   7 │ fn helper() -> i32 { used; }
   8 │ fn unused_fn() -> i32 { 0; }
     ·    ^^^^^^^^^
   9 │ 
  10 │ #[export = "main"]
