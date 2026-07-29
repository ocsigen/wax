An annotation the tokenizer does not interpret is kept as verbatim source text
and travels as trivia, like a comment: printing the module back out preserves
it, nested comments, strings and parentheses included.

  $ wax in.wat -i wat -f wat
  ;; a comment
  (@custom "foo" (; nested ;) "bar" (a (b)) ")" x")"y)
  (@"quoted id" 1 2)
  (global $g (@a) i32 (i32.const 1))
  (func $f (@unknown 1 2 3) (result i32)
    i32.const 42
  )

Wax has no syntax for an annotation, so a conversion to Wax drops it (the
comments are retargeted as usual).

  $ wax in.wat -i wat -f wax
  // a comment
  const g = 1;
  fn f() -> i32 {
      42;
  }
