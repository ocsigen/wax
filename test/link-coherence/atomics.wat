(module
  (memory 1 1 shared)
  (func (export "atomics") (param $i i32) (param $v i64)
    ;; atomic ops (0xFE) exercise Scan's atomic_instruction memarg decoding
    i32.const 0 i32.atomic.load drop
    i32.const 0 i32.atomic.load8_u offset=1 drop
    i32.const 0 i64.atomic.load offset=8 align=8 drop
    i32.const 0 i32.const 1 i32.atomic.store
    i32.const 0 i64.const 1 i64.atomic.store offset=16
    i32.const 0 i32.const 1 i32.atomic.rmw.add drop
    i32.const 0 i64.const 1 i64.atomic.rmw8.and_u offset=2 drop
    i32.const 0 i32.const 1 i32.const 2 i32.atomic.rmw.cmpxchg drop
    i32.const 0 i32.const 1 memory.atomic.notify drop
    i32.const 0 i32.const 1 i64.const -1 memory.atomic.wait32 drop
    atomic.fence
  )
)
