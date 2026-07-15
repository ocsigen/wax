The `eager-select` lint (in the `correctness` group). A Wax `?:` compiles to a
Wasm `select`, which evaluates *both* branches — so a trapping or effectful
operation in a branch runs even when the condition selects the other branch,
unlike the lazy `?:` of most languages.

On Wax source, the type checker flags each hazardous branch and points at the
`?:`. Pure branches (`x + 1`) are silent; a hazard buried under a pure operator
(`1 + (2 /s x)`) is still found; a nested `?:` is linted in its own right (the
inner division here, not the outer arm):

  $ wax check -W eager-select=warning eager.wax
  Warning:
    This operation is evaluated even when the condition selects the other
    branch.
   ──➤  eager.wax:4:37
  2 │ 
  3 │ #[export = "div"]
  4 │ fn div(c: i32, x: i32) -> i32 { c ? 1 /s x : 0; }
    ·                                     ^^^^^^
    ·                                 ^^^^^^^^^^^^^^ This '?:' evaluates both branches (it compiles to a 'select').
  5 │ 
  6 │ #[export = "call"]
  Hint: Use an 'if' expression to evaluate only the chosen branch.
  Warning:
    This operation is evaluated even when the condition selects the other
    branch.
   ──➤  eager.wax:7:30
  5 │ 
  6 │ #[export = "call"]
  7 │ fn call(c: i32) -> i32 { c ? f() : 0; }
    ·                              ^^^
    ·                          ^^^^^^^^^^^ This '?:' evaluates both branches (it compiles to a 'select').
  8 │ 
  9 │ #[export = "pure"]
  Hint: Use an 'if' expression to evaluate only the chosen branch.
  Warning:
    This operation is evaluated even when the condition selects the other
    branch.
    ──➤  eager.wax:13:45
  11 │ 
  12 │ #[export = "buried"]
  13 │ fn buried(c: i32, x: i32) -> i32 { c ? 1 + (2 /s x) : 0; }
     ·                                             ^^^^^^
     ·                                    ^^^^^^^^^^^^^^^^^^^^ This '?:' evaluates both branches (it compiles to a 'select').
  14 │ 
  15 │ #[export = "nested"]
  Hint: Use an 'if' expression to evaluate only the chosen branch.
  Warning:
    This operation is evaluated even when the condition selects the other
    branch.
    ──➤  eager.wax:16:53
  14 │ 
  15 │ #[export = "nested"]
  16 │ fn nested(c: i32, a: i32, x: i32) -> i32 { c ? (a ? 1 /s x : 0) : 7; }
     ·                                                     ^^^^^^
     ·                                                 ^^^^^^^^^^^^^^ This '?:' evaluates both branches (it compiles to a 'select').
  17 │ 
  Hint: Use an 'if' expression to evaluate only the chosen branch.

On WAT the Wasm validator mirrors it for a folded `select` (each value operand
is a distinct subtree). An unfolded `select` leaves its operands on the flat
instruction stream, out of the checker's reach, so it is not flagged:

  $ wax check -W eager-select=warning eager.wat
  Warning:
    This operation is evaluated even when the condition selects the other
    operand.
   ──➤  eager.wat:3:14
  1 │ (module
  2 │   (func $div (export "div") (param $c i32) (param $x i32) (result i32)
  3 │     (select (i32.div_s (i32.const 1) (local.get $x))
    ·              ^^^^^^^^^
    ·      ^^^^^^ This 'select' evaluates both of its operands.
  4 │             (i32.const 0)
  5 │             (local.get $c)))
