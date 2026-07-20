`memory.size` / `table.size` (`m.size()`) reads the current size — it is pure
and never traps, unlike the effectful grow/fill/copy/init on the same path — so
discarding its result is flagged by `unused-result`, matching the Wasm validator.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the group:

  $ wax check -W correctness=warning mem.wax
  Warning [unused-result]:
    The result of this expression is discarded, and computing it has no effect.
   ──➤  mem.wax:5:9
  3 │ #[export = "f"]
  4 │ fn f() {
  5 │     _ = m.size();
    ·         ^^^^^^^^
  6 │ }
  7 │ 
