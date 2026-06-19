Named warnings can be silenced, shown, or promoted to errors with the
repeatable `-W NAME=LEVEL` option. NAME is a warning (e.g. `unused-local`), a
group (e.g. `unused`), or `all`; LEVEL is `hidden`, `warning`, or `error`.

By default an unused local is reported as a warning:

  $ wax --validate unused.wax -f wat
  Warning: The local variable 'dead' is never used.
   ──➤  unused.wax:2:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let dead = 5;
    ·         ^^^^
  3 │     n;
  4 │ }
  (func $f (param $n i32) (result i32)
    (local $dead i32)
    (local.set $dead (i32.const 5))
    (local.get $n)
  )

`-W unused-local=hidden` silences it:

  $ wax --validate -W unused-local=hidden unused.wax -f wat
  (func $f (param $n i32) (result i32)
    (local $dead i32)
    (local.set $dead (i32.const 5))
    (local.get $n)
  )

The `unused` group silences it too:

  $ wax --validate -W unused=hidden unused.wax -f wat
  (func $f (param $n i32) (result i32)
    (local $dead i32)
    (local.set $dead (i32.const 5))
    (local.get $n)
  )

`-W unused-local=error` promotes it to an error (and exits non-zero):

  $ wax --validate -W unused-local=error unused.wax -f wat
  Error: The local variable 'dead' is never used.
   ──➤  unused.wax:2:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let dead = 5;
    ·         ^^^^
  3 │     n;
  4 │ }
  [128]

`-W all=error` makes every warning fatal:

  $ wax --validate -W all=error unused.wax -f wat
  Error: The local variable 'dead' is never used.
   ──➤  unused.wax:2:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let dead = 5;
    ·         ^^^^
  3 │     n;
  4 │ }
  [128]

Later settings override earlier ones: everything fatal except unused locals,
which stay warnings:

  $ wax --validate -W all=error -W unused-local=warning unused.wax -f wat
  Warning: The local variable 'dead' is never used.
   ──➤  unused.wax:2:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let dead = 5;
    ·         ^^^^
  3 │     n;
  4 │ }
  (func $f (param $n i32) (result i32)
    (local $dead i32)
    (local.set $dead (i32.const 5))
    (local.get $n)
  )

The `check` subcommand normally lets an unused local pass (exit status 0), but
promoting it to an error makes the check fail:

  $ wax check unused.wax
  Warning: The local variable 'dead' is never used.
   ──➤  unused.wax:2:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let dead = 5;
    ·         ^^^^
  3 │     n;
  4 │ }

  $ wax check -W unused-local=error unused.wax
  Error: The local variable 'dead' is never used.
   ──➤  unused.wax:2:9
  1 │ fn f(n: i32) -> i32 {
  2 │     let dead = 5;
    ·         ^^^^
  3 │     n;
  4 │ }
  [123]

An unknown warning or group name is rejected:

  $ wax --validate -W bogus=error unused.wax -f wat
  Usage: wax [--help] [COMMAND] …
  wax: option -W: Unknown warning or group 'bogus'. Known names: unused-local,
       truncated-coverage, unused, all.
  [124]

An unknown level is rejected:

  $ wax --validate -W unused-local=loud unused.wax -f wat
  Usage: wax [--help] [COMMAND] …
  wax: option -W: Unknown warning level 'loud'; expected hidden, warning, or
       error.
  [124]
