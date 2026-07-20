The `unused-result` lint (a discarded expression whose computation has no effect)
must classify the same expressions as pure as the Wasm validator does. Pure
numeric methods (`abs`, `rotl`, …) and total casts (a saturating `as i32_s`, a
demote/promote) are effect-free, so discarding one is pointless. Operations that
may trap are not: `array.length()` (null array) and an indexed read stay silent,
as does a `strict` conversion (which traps out of range — its own lint fires
instead). A typed null `null as &?t` is `ref.null` (a constant), so discarding
it is flagged like a bare `null`; a `v128::…` SIMD constructor / vector op is
pure too (the trapping SIMD accesses use the `mem.` path).

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the group:

  $ wax check -W correctness=warning pure.wax
  Warning:
    The result of this expression is discarded, and computing it has no effect.
   ──➤  pure.wax:5:9
  3 │ #[export = "f"]
  4 │ fn f(arr: &a) {
  5 │     _ = (-1).abs();
    ·         ^^^^^^^^^^
  6 │     _ = (2).rotl(3);
  7 │     _ = 100.0 as f32 as i32_s;
  Warning:
    The result of this expression is discarded, and computing it has no effect.
   ──➤  pure.wax:6:9
  4 │ fn f(arr: &a) {
  5 │     _ = (-1).abs();
  6 │     _ = (2).rotl(3);
    ·         ^^^^^^^^^^^
  7 │     _ = 100.0 as f32 as i32_s;
  8 │     _ = arr.length();
  Warning:
    The result of this expression is discarded, and computing it has no effect.
   ──➤  pure.wax:7:9
  5 │     _ = (-1).abs();
  6 │     _ = (2).rotl(3);
  7 │     _ = 100.0 as f32 as i32_s;
    ·         ^^^^^^^^^^^^^^^^^^^^^
  8 │     _ = arr.length();
  9 │     _ = arr[0];
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  pure.wax:14:9
  12 │ #[export = "g"]
  13 │ fn g() {
  14 │     _ = null as &?a;
     ·         ^^^^^^^^^^^
  15 │     _ = v128::i32x4(1, 2, 3, 4);
  16 │ }
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  pure.wax:15:9
  13 │ fn g() {
  14 │     _ = null as &?a;
  15 │     _ = v128::i32x4(1, 2, 3, 4);
     ·         ^^^^^^^^^^^^^^^^^^^^^^^
  16 │ }
  17 │ 

