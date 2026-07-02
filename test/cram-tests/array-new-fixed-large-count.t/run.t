array.new_fixed's element count is a u32 immediate, so it can be huge. Typing it
by popping the element type that many times is O(count) and lets an adversarial
module (count = 2^32-1) tie up the validator. On a polymorphic stack (here, after
[unreachable]) every pop past the base trivially succeeds, so once the stack is
polymorphic the remaining pops are stopped early -- the module is accepted in
time proportional to the operands actually present, matching wasm-tools:

  $ wax check poly.wat

A reachable stack with too few operands still underflows and is rejected (the
first empty pop turns the stack polymorphic, so this is fast too):

  $ wax check underflow.wat
  Error: Type mismatch: the stack is empty (a value is missing).
   ──➤  underflow.wat:5:5
  3 │   (func (result (ref $vec))
  4 │     f32.const 1
  5 │     array.new_fixed $vec 4294967295))
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  6 │ 
  [128]
