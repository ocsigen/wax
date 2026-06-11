Validation reports locals that are declared but never read. A Wax `let` (or a
Wat `(local …)` that is never the target of a `local.get`) is flagged; prefixing
the name with `_` marks it intentionally unused. Parameters are never reported.

  $ wax --validate unused.wax -f wat
  Warning: The local variable 'dead' is never used.
   ──➤  unused.wax:3:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let used = n;
  3 │     let dead = 5;
    ·         ^^^^
  4 │     let _ignored = 9;
  5 │     used;
  (func $f (param $n i32) (result i32)
    (local $used i32) (local $dead i32) (local $_ignored i32)
    (local.set $used (local.get $n))
    (local.set $dead (i32.const 5))
    (local.set $_ignored (i32.const 9))
    (local.get $used)
  )

Without `--validate`, compiling Wax to Wasm does not report unused locals:

  $ wax unused.wax -f wat
  (func $f (param $n i32) (result i32)
    (local $used i32) (local $dead i32) (local $_ignored i32)
    (local.set $used (local.get $n))
    (local.set $dead (i32.const 5))
    (local.set $_ignored (i32.const 9))
    (local.get $used)
  )

For Wat input the check runs under `--validate`. Both named and unnamed locals
are reported; a name starting with `_` is intentionally unused:

  $ wax --validate unused.wat -f wat
  Warning: The local variable $dead is never used.
   ──➤  unused.wat:3:30
  1 │ (module
  2 │   (func $f (param $n i32) (result i32)
  3 │     (local $used i32) (local $dead i32) (local i32) (local $_ignored i32)
    ·                              ^^^^^
  4 │     (local.set $used (local.get $n))
  5 │     (local.get $used)))
  Warning: This local is never used.
   ──➤  unused.wat:3:42
  1 │ (module
  2 │   (func $f (param $n i32) (result i32)
  3 │     (local $used i32) (local $dead i32) (local i32) (local $_ignored i32)
    ·                                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │     (local.set $used (local.get $n))
  5 │     (local.get $used)))
  (func $f (param $n i32) (result i32)
    (local $used i32) (local $dead i32) (local i32) (local $_ignored i32)
    (local.set $used (local.get $n))
    (local.get $used)
  )

The `check` subcommand reports the warning too, but an unused local alone does
not make it fail (exit status stays 0):

  $ wax check unused.wax
  Warning: The local variable 'dead' is never used.
   ──➤  unused.wax:3:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let used = n;
  3 │     let dead = 5;
    ·         ^^^^
  4 │     let _ignored = 9;
  5 │     used;
