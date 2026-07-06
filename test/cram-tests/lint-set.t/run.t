The correctness lint tier is part of the `-W` warning system: each lint is a
named warning, configurable with `-W NAME=LEVEL`, that fires during validation
(`check`, or `convert --validate`). They are shown by default; this test
directory sets `WAX_WARN=correctness=hidden` (see its `dune`), so the commands
below re-enable what they demonstrate with an explicit `-W`.

`-W correctness=warning` shows the whole tier at once:

  $ wax check -W correctness=warning lints.wax
  Warning: The shift count 40 is at least the operand width (32 bits).
   ──➤  lints.wax:5:7
  3 │ #[export = "shift"]
  4 │ fn shift(x: i32) -> i32 {
  5 │     x << 40;
    ·       ^^
  6 │ }
  7 │ 
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
  Warning: This integer division or remainder by zero always traps.
    ──➤  lints.wax:10:7
   8 │ #[export = "divzero"]
   9 │ fn divzero(x: i32) -> i32 {
  10 │     x /s 0;
     ·       ^^
  11 │ }
  12 │ 
  Warning:
    This conversion always traps: the constant is out of the target type's range.
    ──➤  lints.wax:15:5
  13 │ #[export = "trunc"]
  14 │ fn trunc() -> i32 {
  15 │     1e30 as i32_s_strict;
     ·     ^^^^^^^^^^^^^^^^^^^^
  16 │ }
  17 │ 
  Warning: This code is unreachable.
    ──➤  lints.wax:21:5
  18 │ #[export = "dead"]
  19 │ fn dead() -> i32 {
  20 │     return 1;
     ·     ^^^^^^^^ Control never returns from here.
  21 │     2;
     ·     ^
  22 │ }
  23 │ 
  Warning: This comparison is always true.
    ──➤  lints.wax:26:10
  24 │ #[export = "tautology"]
  25 │ fn tautology(x: i32) -> i32 {
  26 │     if x >=u 0 { return 1; }
     ·          ^^^
  27 │     x;
  28 │ }
  Warning: This condition is always false.
    ──➤  lints.wax:32:8
  30 │ #[export = "constcond"]
  31 │ fn constcond(x: i32) -> i32 {
  32 │     if 0 { return 1; }
     ·        ^
  33 │     x;
  34 │ }
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wax:38:9
  36 │ #[export = "unusedresult"]
  37 │ fn unusedresult(x: i32) -> i32 {
  38 │     _ = x + 1;
     ·         ^^^^^
  39 │     x;
  40 │ }
  Warning: The label 'unused' is never used.
    ──➤  lints.wax:44:9
  42 │ #[export = "unusedlabel"]
  43 │ fn unusedlabel(x: i32) -> i32 {
  44 │     _ = 'unused: do { x; };
     ·         ^^^^^^^
  45 │     x;
  46 │ }
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wax:52:17
  50 │ #[export = "unusedalloc"]
  51 │ fn unusedalloc() -> i32 {
  52 │     _: &point = {x: 1, y: 2};
     ·                 ^^^^^^^^^^^^
  53 │     0;
  54 │ }
  Warning: The global 'UNUSED' is never used.
   ──➤  lints.wax:1:7
  1 │ const UNUSED = 42;
    ·       ^^^^^^
  2 │ 
  3 │ #[export = "shift"]

Each lint can be isolated by hiding the group and re-enabling one. A shift by a
constant count at least the operand width — Wasm masks it — with a hint:

  $ wax check -W correctness=hidden -W shift-count-overflow=warning lints.wax
  Warning: The shift count 40 is at least the operand width (32 bits).
   ──➤  lints.wax:5:7
  3 │ #[export = "shift"]
  4 │ fn shift(x: i32) -> i32 {
  5 │     x << 40;
    ·       ^^
  6 │ }
  7 │ 
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.

An operation that always traps on a constant operand (division/remainder by
zero, or an out-of-range trapping conversion):

  $ wax check -W correctness=hidden -W constant-trap=warning lints.wax
  Warning: This integer division or remainder by zero always traps.
    ──➤  lints.wax:10:7
   8 │ #[export = "divzero"]
   9 │ fn divzero(x: i32) -> i32 {
  10 │     x /s 0;
     ·       ^^
  11 │ }
  12 │ 
  Warning:
    This conversion always traps: the constant is out of the target type's range.
    ──➤  lints.wax:15:5
  13 │ #[export = "trunc"]
  14 │ fn trunc() -> i32 {
  15 │     1e30 as i32_s_strict;
     ·     ^^^^^^^^^^^^^^^^^^^^
  16 │ }
  17 │ 

A comparison whose result is constant (here an unsigned value is always `>= 0`):

  $ wax check -W correctness=hidden -W tautological-comparison=warning lints.wax
  Warning: This comparison is always true.
    ──➤  lints.wax:26:10
  24 │ #[export = "tautology"]
  25 │ fn tautology(x: i32) -> i32 {
  26 │     if x >=u 0 { return 1; }
     ·          ^^^
  27 │     x;
  28 │ }

A constant branch/loop/select condition:

  $ wax check -W correctness=hidden -W constant-condition=warning lints.wax
  Warning: This condition is always false.
    ──➤  lints.wax:32:8
  30 │ #[export = "constcond"]
  31 │ fn constcond(x: i32) -> i32 {
  32 │     if 0 { return 1; }
     ·        ^
  33 │     x;
  34 │ }

A statement that can never be reached:

  $ wax check -W correctness=hidden -W dead-code=warning lints.wax
  Warning: This code is unreachable.
    ──➤  lints.wax:21:5
  18 │ #[export = "dead"]
  19 │ fn dead() -> i32 {
  20 │     return 1;
     ·     ^^^^^^^^ Control never returns from here.
  21 │     2;
     ·     ^
  22 │ }
  23 │ 

The result of a side-effect-free expression, computed and discarded:

  $ wax check -W correctness=hidden -W unused-result=warning lints.wax
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wax:38:9
  36 │ #[export = "unusedresult"]
  37 │ fn unusedresult(x: i32) -> i32 {
  38 │     _ = x + 1;
     ·         ^^^^^
  39 │     x;
  40 │ }
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wax:52:17
  50 │ #[export = "unusedalloc"]
  51 │ fn unusedalloc() -> i32 {
  52 │     _: &point = {x: 1, y: 2};
     ·                 ^^^^^^^^^^^^
  53 │     0;
  54 │ }

The `unused` group covers unused module fields and labels (the module-level
analog of `unused-local`); prefix a name with `_` to silence one:

  $ wax check -W correctness=hidden -W unused=warning lints.wax
  Warning: The label 'unused' is never used.
    ──➤  lints.wax:44:9
  42 │ #[export = "unusedlabel"]
  43 │ fn unusedlabel(x: i32) -> i32 {
  44 │     _ = 'unused: do { x; };
     ·         ^^^^^^^
  45 │     x;
  46 │ }
  Warning: The global 'UNUSED' is never used.
   ──➤  lints.wax:1:7
  1 │ const UNUSED = 42;
    ·       ^^^^^^
  2 │ 
  3 │ #[export = "shift"]

`-W correctness=error` promotes the whole tier to errors (non-zero exit):

  $ wax check -W correctness=error lints.wax >/dev/null
  Error: The shift count 40 is at least the operand width (32 bits).
   ──➤  lints.wax:5:7
  3 │ #[export = "shift"]
  4 │ fn shift(x: i32) -> i32 {
  5 │     x << 40;
    ·       ^^
  6 │ }
  7 │ 
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
  Error: This integer division or remainder by zero always traps.
    ──➤  lints.wax:10:7
   8 │ #[export = "divzero"]
   9 │ fn divzero(x: i32) -> i32 {
  10 │     x /s 0;
     ·       ^^
  11 │ }
  12 │ 
  Error:
    This conversion always traps: the constant is out of the target type's range.
    ──➤  lints.wax:15:5
  13 │ #[export = "trunc"]
  14 │ fn trunc() -> i32 {
  15 │     1e30 as i32_s_strict;
     ·     ^^^^^^^^^^^^^^^^^^^^
  16 │ }
  17 │ 
  Error: This code is unreachable.
    ──➤  lints.wax:21:5
  18 │ #[export = "dead"]
  19 │ fn dead() -> i32 {
  20 │     return 1;
     ·     ^^^^^^^^ Control never returns from here.
  21 │     2;
     ·     ^
  22 │ }
  23 │ 
  Error: This comparison is always true.
    ──➤  lints.wax:26:10
  24 │ #[export = "tautology"]
  25 │ fn tautology(x: i32) -> i32 {
  26 │     if x >=u 0 { return 1; }
     ·          ^^^
  27 │     x;
  28 │ }
  Error: This condition is always false.
    ──➤  lints.wax:32:8
  30 │ #[export = "constcond"]
  31 │ fn constcond(x: i32) -> i32 {
  32 │     if 0 { return 1; }
     ·        ^
  33 │     x;
  34 │ }
  Error:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wax:38:9
  36 │ #[export = "unusedresult"]
  37 │ fn unusedresult(x: i32) -> i32 {
  38 │     _ = x + 1;
     ·         ^^^^^
  39 │     x;
  40 │ }
  Error: The label 'unused' is never used.
    ──➤  lints.wax:44:9
  42 │ #[export = "unusedlabel"]
  43 │ fn unusedlabel(x: i32) -> i32 {
  44 │     _ = 'unused: do { x; };
     ·         ^^^^^^^
  45 │     x;
  46 │ }
  Error:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wax:52:17
  50 │ #[export = "unusedalloc"]
  51 │ fn unusedalloc() -> i32 {
  52 │     _: &point = {x: 1, y: 2};
     ·                 ^^^^^^^^^^^^
  53 │     0;
  54 │ }
  Error: The global 'UNUSED' is never used.
   ──➤  lints.wax:1:7
  1 │ const UNUSED = 42;
    ·       ^^^^^^
  2 │ 
  3 │ #[export = "shift"]
  [128]
