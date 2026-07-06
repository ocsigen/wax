(module
  (global $used i32 (i32.const 1))
  (global $unused i32 (i32.const 2))
  (global $_ignored i32 (i32.const 3))
  (global $inline_exported (export "g") i32 (i32.const 4))
  (func $helper (result i32) (global.get $used))
  (func $unused_fn (result i32) (i32.const 0))
  (func $main (export "main") (result i32) (call $helper))
  (func $labels (export "labels")
    (block $unused_block
      (nop))
    (block $used_by_name
      (br $used_by_name))
    (block $used_by_index
      (br 0))))
