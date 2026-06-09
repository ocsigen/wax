Source comments are preserved through the Wax formatter (wax -> wax), the same
way the WAT printer preserves them. Leading comments, block comments, blank
lines between definitions, and end-of-file comments all survive a round-trip.

  $ wax comments.wax -o out.wax && cat out.wax
  // A leading comment on the first function
  fn add(a: i32, b: i32) -> i32 {
      let x: i32 = a; // a trailing comment
      /* a block comment */
      x + b;
  }
  
  // A comment between definitions
  const answer: i32 = 42;
  // A trailing comment at the end of the file
  


The output round-trips to itself.

  $ wax out.wax -o out2.wax && diff out.wax out2.wax
