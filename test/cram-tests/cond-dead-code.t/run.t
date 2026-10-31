Code after a statement that never completes in any configuration is dead in
all of them, a conditional annotation included. Each configuration splices its
branch in, so the first dead instruction is a different one in each; both the
Wax typer and the WAT validator report the conditional statement it comes
from, the one location dead in every configuration (the cram environment hides
the `correctness` group, hence the explicit `-W`).

  $ wax check -W dead-code=warning dead.wax
  Warning [dead-code]: This code is unreachable.
   ──➤  dead.wax:4:5
  1 │ #[export]
  2 │ fn after_return() -> i32 {
  3 │     return 1;
    ·     ^^^^^^^^ Control never returns from here.
  4 │     #[if(p)] { return 2; } #[else] { return 3; }
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  5 │ }
  6 │ #[export]
  Warning [dead-code]: This code is unreachable.
    ──➤  dead.wax:9:5
   6 │ #[export]
   7 │ fn after_conditional() -> i32 {
   8 │     #[if(p)] { return 1; } #[else] { return 2; }
     ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Control never returns from here.
   9 │     #[if(p)] { return 3; } #[else] { return 4; }
     ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  10 │ }
  11 │ 
  $ wax check -W dead-code=warning dead.wat
  Warning [dead-code]: This code is unreachable.
   ──➤  dead.wat:4:5
  1 │ (module
  2 │   (func $after_return (export "after_return") (result i32)
  3 │     (return (i32.const 1))
    ·      ^^^^^^^^^^^^^^^^^^^^^ Control never returns from here.
  4 │     (@if $p (@then (return (i32.const 2))) (@else (return (i32.const 3)))))
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  5 │   (func $after_conditional (export "after_conditional") (result i32)
  6 │     (@if $p (@then (return (i32.const 1))) (@else (return (i32.const 2))))
  Warning [dead-code]: This code is unreachable.
   ──➤  dead.wat:7:5
  4 │     (@if $p (@then (return (i32.const 2))) (@else (return (i32.const 3)))))
  5 │   (func $after_conditional (export "after_conditional") (result i32)
  6 │     (@if $p (@then (return (i32.const 1))) (@else (return (i32.const 2))))
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Control never returns from here.
  7 │     (@if $p (@then (return (i32.const 3))) (@else (return (i32.const 4))))))
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │ 
