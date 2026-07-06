Unfolded WAT prints each instruction on its own line, including nested block and
if bodies.

  $ wax --unfold -f wat nested.wat -o out.wat && cat out.wat
  (func $f (param i32) (result i32)
    local.get 0
    block
      local.get 0
      i32.const 1
      i32.add
    end
    local.get 0
    if (result i32)
      i32.const 1
    else
      i32.const 2
    end
  )
