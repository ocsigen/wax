(module
  (func $block (result i32)
    i32.const 1
    i32.const 2
    block (param i32 i32) (result i32)
      i32.add
    end)
  (func $loop (result i32)
    i32.const 10
    i32.const 20
    i32.const 30
    loop (param i32 i32 i32) (result i32)
      i32.add
      i32.add
    end))
