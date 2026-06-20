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
       truncated-coverage, naming-conflict, reserved-word-rename,
       generated-name, unused, naming, all.
  [124]

An unknown level is rejected:

  $ wax --validate -W unused-local=loud unused.wax -f wat
  Usage: wax [--help] [COMMAND] …
  wax: option -W: Unknown warning level 'loud'; expected hidden, warning, or
       error.
  [124]

Converting from Wasm, a source name may have to be renamed — because it
collides with another (`naming-conflict`) or is a Wax reserved word
(`reserved-word-rename`). Both are hidden by default, so the conversion is
quiet:

  $ wax -i wat -f wax rename.wat
  const foo = 1;
  fn foo_2() -> i32 {
      0;
  }
  fn if_2() -> i32 {
      2;
  }

The `naming` group enables both, each pointing at the renamed identifier and
showing the name before and after:

  $ wax -i wat -f wax -W naming=warning rename.wat
  Warning:
    The name 'foo' is already in use; renaming this occurrence to 'foo_2'.
   ──➤  rename.wat:3:9
  1 │ (module
  2 │   (global $foo i32 (i32.const 1))
    ·           ^^^^ 'foo' first claimed here
  3 │   (func $foo (result i32) (i32.const 0))
    ·         ^^^^
  4 │   (func $if (result i32) (i32.const 2)))
  5 │ 
  Warning: 'if' is a reserved word; renaming this identifier to 'if_2'.
   ──➤  rename.wat:4:9
  2 │   (global $foo i32 (i32.const 1))
  3 │   (func $foo (result i32) (i32.const 0))
  4 │   (func $if (result i32) (i32.const 2)))
    ·         ^^^
  5 │ 
  const foo = 1;
  fn foo_2() -> i32 {
      0;
  }
  fn if_2() -> i32 {
      2;
  }

They can be enabled individually, and promoted to an error like any warning:

  $ wax -i wat -f wax -W reserved-word-rename=error rename.wat
  Error: 'if' is a reserved word; renaming this identifier to 'if_2'.
   ──➤  rename.wat:4:9
  2 │   (global $foo i32 (i32.const 1))
  3 │   (func $foo (result i32) (i32.const 0))
  4 │   (func $if (result i32) (i32.const 2)))
    ·         ^^^
  5 │ 
  [128]

An unnamed parameter that is referenced cannot be rendered anonymously, so a
name is generated for it. The `generated-name` warning (also in the `naming`
group, hidden by default) reports this, pointing at the function:

  $ wax -i wat -f wax genname.wat
  fn f(x: i32) -> i32 {
      x;
  }

  $ wax -i wat -f wax -W generated-name=warning genname.wat
  Warning: An unnamed parameter is used; generating the name 'x' for it.
   ──➤  genname.wat:2:4
  1 │ (module
  2 │   (func (param i32) (result i32)
    ·    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │     (local.get 0)))
    · ^^^^^^^^^^^^^^^^^^
  4 │ 
  fn f(x: i32) -> i32 {
      x;
  }

The same renaming applies to parameter names in a function-type signature: a
reserved word or a duplicate is disambiguated, so the type still re-parses,
and the `naming` warnings report it:

  $ wax -i wat -f wax -W naming=warning sigparam.wat
  Warning: 'if' is a reserved word; renaming this identifier to 'if_2'.
   ──➤  sigparam.wat:3:18
  1 │ (module
  2 │   (type $t
  3 │     (func (param $if i32) (param $x i32) (param $x i32) (result i32))))
    ·                  ^^^
  4 │ 
  Warning: The name 'x' is already in use; renaming this occurrence to 'x_2'.
   ──➤  sigparam.wat:3:49
  1 │ (module
  2 │   (type $t
  3 │     (func (param $if i32) (param $x i32) (param $x i32) (result i32))))
    ·                                                 ^^
    ·                                  ^^ 'x' first claimed here
  4 │ 
  type t = fn(if_2: i32, x: i32, x_2: i32) -> i32;

Labels are renamed when one shadows an enclosing label of the same name, but
only when the inner label is actually referenced (an unused label is dropped):

  $ wax -i wat -f wax -W naming=warning label.wat
  Warning: The name 'x' is already in use; renaming this occurrence to 'x_2'.
   ──➤  label.wat:4:14
  1 │ (module
  2 │   (func $f (result i32)
  3 │     (block $x (result i32)
    ·            ^^ 'x' first claimed here
  4 │       (block $x (result i32) (br $x (i32.const 1))))))
    ·              ^^
  5 │ 
  fn f() -> i32 {
      do i32 {
          'x_2: do i32 {
              br 'x_2 1;
          }
      }
  }
