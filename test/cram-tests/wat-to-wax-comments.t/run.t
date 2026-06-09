Source comments are preserved when converting WAT to Wax. The comment
delimiters are translated from WAT syntax (;; and (; ;)) to Wax syntax (// and
/* */). A WAT `call_indirect` desugars into several Wax nodes ((t[i] as &?ft)(x));
its leading comment must still be emitted exactly once, not once per node.

  $ wax in.wat -i wat -f wax -o out.wax && cat out.wax
  // A leading comment
  type ft = fn(i32) -> i32;
  table t: &?func [1];
  // an indirect-call helper
  fn call(i: i32, x: i32) -> i32 { (t[i] as &?ft)(x); }
  // a global
  const answer = 42;
  // End of file
  
