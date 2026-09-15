A `#[if]` branch that no configuration selects -- its condition contradicts the
enclosing conditionals', or itself -- is reported once as `dead-code`, at the
conditional, naming the branch (the cram environment hides the `correctness`
group, hence the explicit `-W`). Only the outermost of a dead nest is reported: a
conditional inside a dead branch is never decided. A branch merely narrowed by
the enclosing conditions (here `all(debug, wasi)` under `debug`) is live.

  $ wax check -W dead-code=warning dead.wax
  Warning [dead-code]:
    The then-branch of this conditional is unreachable: no configuration selects
    it.
    ──➤  dead.wax:4:9
   2 │ {
   3 │     fn f() -> i32 {
   4 │         #[if(not(debug))]
     · ╭───────^
   5 │         {
     · │
   6 │             1
     · │
     · ...
   9 │         {
     · │
  10 │             2
     · │
  11 │         }
     · ╰───────^
  12 │     }
  13 │     #[if(all(debug, wasi))]
  Warning [dead-code]:
    The then-branch of this conditional is unreachable: no configuration selects
    it.
    ──➤  dead.wax:22:1
  20 │     }
  21 │ }
  22 │ #[if(all(fast, not(fast)))]
     · ╭
  23 │ {
     · │
  24 │     fn never() {}
     · │
  25 │ }
     · ╰
  26 │ 

The Wasm validator mirrors it:

  $ wax check -W dead-code=warning dead.wat
  Warning [dead-code]:
    The @then branch of this conditional is unreachable: no configuration
    selects it.
   ──➤  dead.wat:5:9
  3 │     (@then
  4 │       (func $f (result i32)
  5 │         (@if (not $debug) (@then i32.const 1) (@else i32.const 2)))))
    ·         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  6 │   (@if (and $fast (not $fast)) (@then (func $never))))
  7 │ 
  Warning [dead-code]:
    The @then branch of this conditional is unreachable: no configuration
    selects it.
   ──➤  dead.wat:6:3
  4 │       (func $f (result i32)
  5 │         (@if (not $debug) (@then i32.const 1) (@else i32.const 2)))))
  6 │   (@if (and $fast (not $fast)) (@then (func $never))))
    ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  7 │ 

Converting does not report it (no validation of a same-format conversion), but
`--validate` does:

  $ wax dead.wax -f wax >/dev/null
  $ wax --validate -W dead-code=warning dead.wax -f wat >/dev/null
  Warning [dead-code]:
    The then-branch of this conditional is unreachable: no configuration selects
    it.
    ──➤  dead.wax:4:9
   2 │ {
   3 │     fn f() -> i32 {
   4 │         #[if(not(debug))]
     · ╭───────^
   5 │         {
     · │
   6 │             1
     · │
     · ...
   9 │         {
     · │
  10 │             2
     · │
  11 │         }
     · ╰───────^
  12 │     }
  13 │     #[if(all(debug, wasi))]
  Warning [dead-code]:
    The then-branch of this conditional is unreachable: no configuration selects
    it.
    ──➤  dead.wax:22:1
  20 │     }
  21 │ }
  22 │ #[if(all(fast, not(fast)))]
     · ╭
  23 │ {
     · │
  24 │     fn never() {}
     · │
  25 │ }
     · ╰
  26 │ 
