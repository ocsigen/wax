A constant `f32` has no literal suffix, so it is written `<lit> as f32`. The
`constant-trap` lint for a trapping float-to-integer conversion must still see
the constant through that demote: `1e30 as f32 as i32_u_strict` traps (the value
is far out of `i32` range), while an in-range constant does not. This mirrors the
Wasm validator, which sees the folded `f32.const` directly.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the group:

  $ wax check -W correctness=warning trap.wax
  Warning:
    This conversion always traps: the constant is out of the target type's
    range.
   ──➤  trap.wax:2:24
  1 │ #[export = "trap_f32"]
  2 │ fn trap_f32() -> i32 { 1e30 as f32 as i32_u_strict; }
    ·                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ 
  4 │ #[export = "ok_f32"]
