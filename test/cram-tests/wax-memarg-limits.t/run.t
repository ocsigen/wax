Wax type-checking enforces the same static constraints the Wasm validator
does for memory access immediates and memory/table size limits.

A memory-access alignment may not exceed the access's natural alignment:

  $ wax check align.wax
  Error: The memory alignment is larger than the natural alignment 1.
   ──➤  align.wax:1:44
  1 │ memory m: i32 [0]; fn f() { _ = m.load8(0, 2) as i32_s; }
    ·                                            ^
  2 │ 
  [123]

The lane index of a SIMD lane operation must be in range for the shape:

  $ wax check lane.wax
  Error: The lane index should be less than 16.
   ──➤  lane.wax:2:89
  1 │ fn f() -> i32 {
  2 │   v128_const_i8x16(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0).extract_lane_s_i8x16(16);
    ·                                                                                         ^^
  3 │ }
  4 │ 
  [123]

A memory's size limit must fit the address type:

  $ wax check memory-size.wax
  Error: The memory size is too large. It should be less than 0x10000.
   ──➤  memory-size.wax:1:1
  1 │ memory m: i32 [65537];
    · ^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

The minimum of a limit must not exceed the maximum:

  $ wax check min-max.wax
  Error: The memory maximum size should be larger than the minimal size.
   ──➤  min-max.wax:1:1
  1 │ memory m: i32 [1, 0];
    · ^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

A memory offset immediate must fit the address type:

  $ wax check offset.wax
  Error: The memory offset should be less than 0x100000000.
   ──➤  offset.wax:1:48
  1 │ memory m: i32 [1]; fn f() { _ = m.load32(0, 4, 4294967296); }
    ·                                                ^^^^^^^^^^
  2 │ 
  [123]

Table size limits are checked too:

  $ wax check table-size.wax
  Error: The table size is too large. It should be less than 0xffffffff.
   ──➤  table-size.wax:1:1
  1 │ table t: &?func [4294967296];
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

A table whose element type is non-nullable must have an initializer (otherwise
its default-filled elements would have no value):

  $ wax check non-nullable-table.wax
  Error: A table with a non-nullable element type must have an initializer.
   ──➤  non-nullable-table.wax:1:1
  1 │ table t: &func [0];
    · ^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

Giving an initializer, or using a nullable element type, is fine:

  $ wax check nullable-or-init-table.wax

A module may not export the same name twice:

  $ wax check dup-export.wax
  Error: There is already an export of name "a".
   ──➤  dup-export.wax:2:12
  1 │ #[export = "a"]
  2 │ #[export = "a"]
    ·            ^^^
  3 │ fn a() {}
  4 │ 
  [123]

Exporting one item under several distinct names, or different items under
distinct names, is fine:

  $ wax check distinct-exports.wax

A module that respects all of these passes silently:

  $ wax check ok.wax
