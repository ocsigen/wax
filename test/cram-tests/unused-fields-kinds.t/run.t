`unused-field` / `unused-import` cover every module field kind that can be
referenced by name, not just functions and globals: a memory, a table, a tag, and
a *passive* data or element segment. An active segment (and a declarative one)
runs at instantiation, so it is used whether or not an instruction names it; only
a passive segment, reachable solely through `memory.init`/`table.init` and
`data.drop`/`elem.drop`, can be dead. As always, a leading `_` marks a
declaration as deliberately unused.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the `unused`
group explicitly.

On WebAssembly text (the validator):

  $ wax check -W unused=warning kinds.wat
  Warning [unused-field]: The memory '$unused_mem' is never used.
   ──➤  kinds.wat:6:11
  4 │   (import "env" "unused_tag" (tag $imported_tag (param i32)))
  5 │   (memory $used_mem 1)
  6 │   (memory $unused_mem 1)
    ·           ^^^^^^^^^^^
  7 │   (memory $_ignored_mem 1)
  8 │   (table $used_tab 1 funcref)
  Warning [unused-field]: The table '$unused_tab' is never used.
    ──➤  kinds.wat:9:10
   7 │   (memory $_ignored_mem 1)
   8 │   (table $used_tab 1 funcref)
   9 │   (table $unused_tab 1 funcref)
     ·          ^^^^^^^^^^^
  10 │   (tag $used_tag (param i32))
  11 │   (tag $unused_tag (param i32))
  Warning [unused-field]: The tag '$unused_tag' is never used.
    ──➤  kinds.wat:11:8
   9 │   (table $unused_tab 1 funcref)
  10 │   (tag $used_tag (param i32))
  11 │   (tag $unused_tag (param i32))
     ·        ^^^^^^^^^^^
  12 │   (data $used_data "ab")
  13 │   (data $unused_data "cd")
  Warning [unused-field]: The data segment '$unused_data' is never used.
    ──➤  kinds.wat:13:9
  11 │   (tag $unused_tag (param i32))
  12 │   (data $used_data "ab")
  13 │   (data $unused_data "cd")
     ·         ^^^^^^^^^^^^
  14 │   (data (memory $used_mem) (i32.const 0) "active")
  15 │   (elem $used_elem funcref (ref.func $f))
  Warning [unused-field]: The element segment '$unused_elem' is never used.
    ──➤  kinds.wat:16:9
  14 │   (data (memory $used_mem) (i32.const 0) "active")
  15 │   (elem $used_elem funcref (ref.func $f))
  16 │   (elem $unused_elem funcref)
     ·         ^^^^^^^^^^^^
  17 │   (elem (table $used_tab) (i32.const 0) funcref (ref.func $f))
  18 │   (func $f (export "f")
  Warning [unused-import]: The imported memory '$imported_mem' is never used.
   ──➤  kinds.wat:2:38
  1 │ (module
  2 │   (import "env" "unused_mem" (memory $imported_mem 1))
    ·                                      ^^^^^^^^^^^^^
  3 │   (import "env" "unused_tab" (table $imported_tab 1 funcref))
  4 │   (import "env" "unused_tag" (tag $imported_tag (param i32)))
  Warning [unused-import]: The imported table '$imported_tab' is never used.
   ──➤  kinds.wat:3:37
  1 │ (module
  2 │   (import "env" "unused_mem" (memory $imported_mem 1))
  3 │   (import "env" "unused_tab" (table $imported_tab 1 funcref))
    ·                                     ^^^^^^^^^^^^^
  4 │   (import "env" "unused_tag" (tag $imported_tag (param i32)))
  5 │   (memory $used_mem 1)
  Warning [unused-import]: The imported tag '$imported_tag' is never used.
   ──➤  kinds.wat:4:35
  2 │   (import "env" "unused_mem" (memory $imported_mem 1))
  3 │   (import "env" "unused_tab" (table $imported_tab 1 funcref))
  4 │   (import "env" "unused_tag" (tag $imported_tag (param i32)))
    ·                                   ^^^^^^^^^^^^^
  5 │   (memory $used_mem 1)
  6 │   (memory $unused_mem 1)

The same module written in Wax reports the same set (the type checker mirrors the
validator):

  $ wax check -W unused=warning kinds.wax
  Warning [unused-import]: The imported memory 'imported_mem' is never used.
   ──➤  kinds.wax:2:10
  1 │ import "env" {
  2 │   memory imported_mem: i32 [1];
    ·          ^^^^^^^^^^^^
  3 │   table imported_tab: &?func [1];
  4 │   tag imported_tag(i32);
  Warning [unused-import]: The imported table 'imported_tab' is never used.
   ──➤  kinds.wax:3:9
  1 │ import "env" {
  2 │   memory imported_mem: i32 [1];
  3 │   table imported_tab: &?func [1];
    ·         ^^^^^^^^^^^^
  4 │   tag imported_tag(i32);
  5 │ }
  Warning [unused-import]: The imported tag 'imported_tag' is never used.
   ──➤  kinds.wax:4:7
  2 │   memory imported_mem: i32 [1];
  3 │   table imported_tab: &?func [1];
  4 │   tag imported_tag(i32);
    ·       ^^^^^^^^^^^^
  5 │ }
  6 │ 
  Warning [unused-field]: The memory 'unused_mem' is never used.
    ──➤  kinds.wax:8:8
   6 │ 
   7 │ memory used_mem: i32 [1];
   8 │ memory unused_mem: i32 [1];
     ·        ^^^^^^^^^^
   9 │ memory _ignored_mem: i32 [1];
  10 │ table used_tab: &?func [1];
  Warning [unused-field]: The table 'unused_tab' is never used.
    ──➤  kinds.wax:11:7
   9 │ memory _ignored_mem: i32 [1];
  10 │ table used_tab: &?func [1];
  11 │ table unused_tab: &?func [1];
     ·       ^^^^^^^^^^
  12 │ tag used_tag(i32);
  13 │ tag unused_tag(i32);
  Warning [unused-field]: The tag 'unused_tag' is never used.
    ──➤  kinds.wax:13:5
  11 │ table unused_tab: &?func [1];
  12 │ tag used_tag(i32);
  13 │ tag unused_tag(i32);
     ·     ^^^^^^^^^^
  14 │ data used_data = "ab";
  15 │ data unused_data = "cd";
  Warning [unused-field]: The data segment 'unused_data' is never used.
    ──➤  kinds.wax:15:6
  13 │ tag unused_tag(i32);
  14 │ data used_data = "ab";
  15 │ data unused_data = "cd";
     ·      ^^^^^^^^^^^
  16 │ data active_data @ used_mem [0] = "active";
  17 │ elem used_elem: &?func = [f];
  Warning [unused-field]: The element segment 'unused_elem' is never used.
    ──➤  kinds.wax:18:6
  16 │ data active_data @ used_mem [0] = "active";
  17 │ elem used_elem: &?func = [f];
  18 │ elem unused_elem: &?func = [];
     ·      ^^^^^^^^^^^
  19 │ 
  20 │ #[export = "f"]
