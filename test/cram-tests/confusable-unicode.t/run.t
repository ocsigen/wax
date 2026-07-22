A "Trojan Source" bidirectional control character in a string (here U+202E,
right-to-left override, in an export name) can make the source read differently
than it runs. The `confusable-unicode` lint reports it — on Wax and, via the
validator, on the equivalent WAT.

  $ wax check -W confusable-unicode=warning bidi.wax
  Warning [confusable-unicode]:
    This string contains a bidirectional control character (U+202E) that can
    make the displayed text read differently than it runs.
   ──➤  bidi.wax:1:12
  1 │ #[export = "ev‮il"]
    ·            ^^^^^^
  2 │ fn f() -> i32 {
  3 │     0;

  $ wax -i wax -f wat bidi.wax -o bidi.wat
  $ wax check -f wat -W confusable-unicode=warning bidi.wat
  Warning [confusable-unicode]:
    This string contains a bidirectional control character (U+202E) that can
    make the displayed text read differently than it runs.
   ──➤  bidi.wat:1:18
  1 │ (func $f (export "ev‮il") (result i32) (i32.const 0))
    ·                  ^^^^^^
  2 │ 
