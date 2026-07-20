Validation reports locals that are declared but never read. A Wax `let` (or a
Wat `(local …)` that is never the target of a `local.get`) is flagged; prefixing
the name with `_` marks it intentionally unused. Parameters are never reported.

  $ wax --validate unused.wax -f wat
  Warning [unused-local]: The local variable 'dead' is never used.
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
  Warning [unused-local]: The local variable '$dead' is never used.
   ──➤  unused.wat:3:30
  1 │ (module
  2 │   (func $f (param $n i32) (result i32)
  3 │     (local $used i32) (local $dead i32) (local i32) (local $_ignored i32)
    ·                              ^^^^^
  4 │     (local.set $used (local.get $n))
  5 │     (local.get $used)))
  Warning [unused-local]: This local is never used.
   ──➤  unused.wat:3:41
  1 │ (module
  2 │   (func $f (param $n i32) (result i32)
  3 │     (local $used i32) (local $dead i32) (local i32) (local $_ignored i32)
    ·                                         ^^^^^^^^^^^
  4 │     (local.set $used (local.get $n))
  5 │     (local.get $used)))
  (func $f (param $n i32) (result i32)
    (local $used i32) (local $dead i32) (local i32) (local $_ignored i32)
    (local.set $used (local.get $n))
    (local.get $used)
  )

Under conditional annotations the check is path-sensitive: a local is reported
only when it is unused in *every* reachable configuration. `$used_when_wasi` is
read in the `$wasi` branch, so it is never flagged even though the `(not $wasi)`
configuration leaves it unread; `$never_used` is read in no branch, so it is
reported (with no "reachable when" qualifier, as it holds unconditionally):

  $ wax --validate cond.wat -f wat
  Warning [unused-local]: The local variable '$never_used' is never used.
   ──➤  cond.wat:3:40
  1 │ (module
  2 │   (func $f (param $n i32) (result i32)
  3 │     (local $used_when_wasi i32) (local $never_used i32)
    ·                                        ^^^^^^^^^^^
  4 │     (local.set $used_when_wasi (local.get $n))
  5 │     (@if $wasi
  (func $f (param $n i32) (result i32)
    (local $used_when_wasi i32) (local $never_used i32)
    (local.set $used_when_wasi (local.get $n))
    (@if $wasi (@then (local.get $used_when_wasi)) (@else (i32.const 0)))
  )

The same path-sensitivity applies to Wax `#[if]`/`#[else]`: `used_when_wasi` is
read only in the `wasi` branch but is still not flagged, while `never_used` is
reported once, unconditionally.

  $ wax --validate cond.wax -f wax
  Warning [unused-local]: The local variable 'never_used' is never used.
   ──➤  cond.wax:3:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let used_when_wasi: i32 = n;
  3 │     let never_used: i32 = 5;
    ·         ^^^^^^^^^^
  4 │     #[if(wasi)]
  5 │     {
  fn f(n: i32) -> i32 {
      let used_when_wasi: i32 = n;
      let never_used: i32 = 5;
      #[if(wasi)]
      {
          used_when_wasi;
      }
      #[else]
      {
          0;
      }
  }

The `check` subcommand reports the warning too, but an unused local alone does
not make it fail (exit status stays 0):

  $ wax check unused.wax
  Warning [unused-local]: The local variable 'dead' is never used.
   ──➤  unused.wax:3:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let used = n;
  3 │     let dead = 5;
    ·         ^^^^
  4 │     let _ignored = 9;
  5 │     used;
