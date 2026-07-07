The `WAX_WARN` environment variable seeds warning levels before any `-W`. It is
a list of `NAME=LEVEL` specs separated by commas or whitespace.

This test directory sets `WAX_WARN=correctness=hidden` (see its `dune`), so the
`shift-count-overflow` lint on `x << 40` is quiet by default:

  $ wax check f.wax

An inline value overrides the directory's; here it promotes the lint to an error
(non-zero exit):

  $ WAX_WARN=shift-count-overflow=error wax check f.wax
  Error: The shift count 40 is at least the operand width (32 bits).
   ──➤  f.wax:3:7
  1 │ #[export = "f"]
  2 │ fn f(x: i32) -> i32 {
  3 │     x << 40;
    ·       ^^
  4 │ }
  5 │ 
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
  [128]

Unlike cmdliner's built-in environment fallback, `WAX_WARN` still applies when
`-W` is given: the command line only refines it. Here the environment asks for
an error but `-W` relaxes this one lint back to a warning (exit zero):

  $ WAX_WARN=shift-count-overflow=error wax check -W shift-count-overflow=warning f.wax
  Warning: The shift count 40 is at least the operand width (32 bits).
   ──➤  f.wax:3:7
  1 │ #[export = "f"]
  2 │ fn f(x: i32) -> i32 {
  3 │     x << 40;
    ·       ^^
  4 │ }
  5 │ 
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.

A malformed or unknown entry is reported on stderr and skipped, rather than
aborting the run (the remaining default policy still shows the lint):

  $ WAX_WARN=bogus=error wax check f.wax
  wax: WAX_WARN: Unknown warning or group 'bogus'. Known names: unused-local, unused-field, unused-import, unused-label, shift-count-overflow, constant-trap, tautological-comparison, constant-condition, unused-result, dead-code, cast-always-fails, eager-select, redundant-operation, truncated-coverage, naming-conflict, reserved-word-rename, generated-name, unused, correctness, redundant, naming, all.
  Warning: The shift count 40 is at least the operand width (32 bits).
   ──➤  f.wax:3:7
  1 │ #[export = "f"]
  2 │ fn f(x: i32) -> i32 {
  3 │     x << 40;
    ·       ^^
  4 │ }
  5 │ 
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
