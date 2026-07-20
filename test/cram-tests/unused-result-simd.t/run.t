A SIMD vector method on a value (`v.abs_i32x4()`, `v.add_i32x4(w)`) is pure and
never traps — the trapping SIMD accesses are the `mem.`-path loads/stores — so
discarding its result is a pointless computation, flagged like any other, and
matching the Wasm validator.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the group:

  $ wax check -W correctness=warning simd.wax
  Warning:
    The result of this expression is discarded, and computing it has no effect.
   ──➤  simd.wax:3:9
  1 │ #[export = "f"]
  2 │ fn f(v: v128) {
  3 │     _ = v.abs_i32x4();
    ·         ^^^^^^^^^^^^^
  4 │     _ = v.add_i32x4(v);
  5 │ }
  Warning:
    The result of this expression is discarded, and computing it has no effect.
   ──➤  simd.wax:4:9
  2 │ fn f(v: v128) {
  3 │     _ = v.abs_i32x4();
  4 │     _ = v.add_i32x4(v);
    ·         ^^^^^^^^^^^^^^
  5 │ }
  6 │ 
