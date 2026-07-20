A malformed Wasm *binary* whose global initializer references a not-yet-declared
global (a forward reference — a constant expression may only read an earlier
global) must be rejected, just as the equivalent text is. The decoder synthesizes
names with no source location, which must not be mistaken for parser-recovery
placeholders (that suppression applies only in recovery mode).

`fwd.wasm` is the minimal invalid module: two i32 globals, where global 0's
initializer is `global.get 1`.

  $ wax check fwd.wasm
  Error: Unknown global: index '1' is not bound.
  [128]
