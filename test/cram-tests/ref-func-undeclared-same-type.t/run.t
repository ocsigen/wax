A `ref.func` in a function body is valid only if that function is declared
referenceable (occurs in a global, element segment, or export). The validator
tracked declared functions by their TYPE rather than their index, so declaring
one function marked every same-typed function referenceable: here `$a` (declared
via the global) made `$b` — referenced only in a body — wrongly pass. It is now
tracked by function index, so the undeclared `$b` is rejected, matching the
reference validator. Regression: structure-aware wasm mutation (mutate-wasm
MODE=struct) via the reference differential.

  $ wax check bad.wasm
  File "bad.wasm", line 1, characters 43-45:
  Error: The function '$b' is not declared as referenceable ('ref.func').
  [128]
