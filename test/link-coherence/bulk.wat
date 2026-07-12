(module
  (memory 1)
  (table 4 funcref)
  (type $t (func))
  (elem func 0 0)
  (data "abcd")
  (func $f)
  (func (export "bulk") (param $i i32)
    ;; 0xFC family: bulk memory + table ops (dataidx/elemidx/tableidx immediates)
    i32.const 0 i32.const 0 i32.const 4 memory.init 0
    data.drop 0
    i32.const 0 i32.const 0 i32.const 1 memory.copy
    i32.const 0 i32.const 0 i32.const 1 memory.fill
    i32.const 0 i32.const 0 i32.const 1 table.init 0
    elem.drop 0
    i32.const 0 i32.const 0 i32.const 1 table.copy
    ref.null func i32.const 1 table.grow drop
    table.size drop
    i32.const 0 ref.null func i32.const 1 table.fill
    ;; trunc_sat (0xFC 00..07)
    f32.const 1.5 i32.trunc_sat_f32_s drop
    f64.const 1.5 i64.trunc_sat_f64_u drop
    ;; table.get/set, call_indirect (typeidx+tableidx), select-typed, br_table
    i32.const 0 table.get drop
    i32.const 0 ref.null func table.set
    i32.const 0 call_indirect (type $t)
    i32.const 1 i32.const 2 i32.const 0 select (result i32) drop
    block block i32.const 0 br_table 0 1 0 end end
    ;; assorted integer load/store memarg widths
    i32.const 0 i32.load8_s offset=1 drop
    i32.const 0 i32.load16_u align=1 drop
    i32.const 0 i64.load32_s offset=7 align=4 drop
    i32.const 0 i32.const 1 i32.store8 offset=3
    i32.const 0 i64.const 1 i64.store16 offset=6 align=2
  )
)
