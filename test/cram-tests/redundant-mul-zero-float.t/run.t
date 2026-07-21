The `redundant-operation` lint reports `x * 0` as always yielding 0, but that
holds only for integers: a float `x * 0` is `NaN` when `x` is `NaN` or an
infinity (and `0` propagates the sign otherwise), so its result is not a
constant. Only the integer form is flagged, matching the Wasm validator (which
runs these checks only for integer binops). A flexible `0` literal whose sibling
operand is a concrete float must not be misread as an integer multiply.

  $ wax check -W redundant=warning mul.wax
  Warning [redundant-operation]: This operation always yields 0.
   ──➤  mul.wax:2:32
  1 │ #[export = "int_mul0"]
  2 │ fn int_mul0(x: i32) -> i32 { x * 0; }
    ·                                ^
  3 │ 
  4 │ #[export = "float_mul0"]
