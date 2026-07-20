The `redundant-operation` lint reports `x - x` as always yielding 0, but that
holds only for integers: a float `x - x` is `NaN` when `x` is `NaN` or an
infinity, so its result is not a constant. Only the integer form is flagged,
matching the Wasm validator.

  $ wax check -W redundant=warning sub.wax
  Warning: This operation always yields 0.
   ──➤  sub.wax:2:31
  1 │ #[export = "int_sub"]
  2 │ fn int_sub(x: i32) -> i32 { x - x; }
    ·                               ^
  3 │ 
  4 │ #[export = "float_sub"]
