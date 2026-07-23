Some syntax errors are raised by a grammar semantic action *as it reduces*,
not by the parser meeting an unexpected token: Wax's `#[else]` pairing check
(`process_stmts`) and WAT's `(pagesize N)` power-of-two check are two. Under
`--all-errors` these used to abort the whole parse — the error was reported but
the rest of the file was never examined — because the raise escaped mid-parse to
the top-level backstop. Recovery now catches such a raise at the reduction
point, discards the failed production's operands so it cannot re-fire, and
resynchronizes like any other syntax error, so later errors still surface.

A statement-level `#[else]` with no preceding `#[if]` raises while the function
body reduces; recovery continues, so the malformed parameter list on the next
line is reported too:

  $ wax check --all-errors stmt-raise.wax
  Error: An '#[else]' must directly follow an '#[if(...)]' group.
   ──➤  stmt-raise.wax:1:10
  1 │ fn a() { #[else] { 1; } }
    ·          ^^^^^^^^^^^^^^
  2 │ fn b( { }
  3 │ 
  Error: Expecting ')', or a function parameter.
   ──➤  stmt-raise.wax:2:7
  1 │ fn a() { #[else] { 1; } }
  2 │ fn b( { }
    ·       ^
    ·     ^ This '(' opens the enclosing construct.
  3 │ 
  [128]

A module-level `#[else]` raises at the *final* reduction, after the whole file
has been consumed and recovery has already handled the broken `fn b(`. Both
errors are reported (this case already worked via the backstop; it must not
regress):

  $ wax check --all-errors module-else.wax
  Error: Expecting ')', or a function parameter.
   ──➤  module-else.wax:3:7
  1 │ fn a() { }
  2 │ #[else] { fn e() {} }
  3 │ fn b( { }
    ·       ^
    ·     ^ This '(' opens the enclosing construct.
  4 │ 
  Error: An '#[else]' must directly follow an '#[if(...)]' field.
   ──➤  module-else.wax:2:1
  1 │ fn a() { }
  2 │ #[else] { fn e() {} }
    · ^^^^^^^^^^^^^^^^^^^^^
  3 │ fn b( { }
  4 │ 
  [128]

The same holds for WAT: `(pagesize 3)` raises while the memory field reduces,
and recovery goes on to report the type-less `(global $g)`:

  $ wax check --all-errors pagesize.wat
  Error: The page size must be a power of two.
   ──➤  pagesize.wat:2:21
  1 │ (module
  2 │   (memory (pagesize 3))
    ·                     ^
  3 │   (func $f (result i32) (i32.const 1))
  4 │   (global $g)
  Error:
    Assuming that the exports are complete, expecting a global type, or an
    inline import.
   ──➤  pagesize.wat:4:13
  2 │   (memory (pagesize 3))
  3 │   (func $f (result i32) (i32.const 1))
  4 │   (global $g)
    ·             ^
  5 │ )
  6 │ 
  [128]
