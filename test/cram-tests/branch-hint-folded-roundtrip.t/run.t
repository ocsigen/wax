A branch hint on a *folded* conditional branch must survive a binary
round-trip. The hint's byte offset in the `metadata.code.branch_hint` section is
the branch opcode's — which, for a folded branch, is emitted only after the
folded operands (the condition). Recording the wrapper's start offset instead
would point the hint at the condition, so on decode it misses the `if` and the
hint is silently dropped. Regression: found via the vendored branch_hint.wast.

  $ wax -i wat -f wasm folded.wat -o folded.wasm
  $ wax -i wasm -f wat folded.wasm
  (type (func (param i32) (result i32)))
  (func (param i32) (result i32)
    local.get 0
    (@metadata.code.branch_hint "\00")
    if (result i32)
      i32.const 1
    else
      i32.const 2
    end
  )
