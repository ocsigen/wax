(module
  (tag $a (param i32))
  (tag $b (param i32 i64))
  (tag $c)

  ;; numeric branches from the body (to the try, past it) and from handlers
  (func $depths (param i32) (result i32)
    block (result i32)
      try (result i32)
        i32.const 100
        local.get 0
        br_table 0 1 0
      catch $a
        local.get 0
        br_if 1
        i32.const 1
        i32.add
      catch $b
        i32.wrap_i64
        i32.add
        br 0
      catch_all
        i32.const 7
      end
    end)

  ;; block parameters, a catch_all only, and no handler at all
  (func $params (param i32) (result i32)
    local.get 0
    i32.const 3
    try (param i32 i32) (result i32)
      i32.add
    catch_all
      i32.const 9
    end
    try
    end)

  ;; nested: the inner try's handler branches to the outer try
  (func $nested (param i32) (result i32)
    try $outer (result i32)
      try (result i32)
        local.get 0
      catch $c
        i32.const 77
        br $outer
      end
    catch $a
    end)
)
