An empty block body stays `{}` on its own line, but when the enclosing
construct breaks anyway — an empty `if` arm beside a multi-line `else`, an empty
`try` body beside a `catch` — the `}` drops to the next line rather than the
opening `{` wrapping oddly. Regression test for that formatting.

  $ wax -f wax empty.wax
  fn with_else(c: i32) {
      if c {
      } else {
          nop;
      }
  }
  
  fn standalone(c: i32) {
      if c {}
  }
  
  tag e();
  
  fn with_catch() {
      try {
      } catch {
          e => {}
      }
  }




Formatting is idempotent — the result formats to itself:

  $ wax -f wax empty.wax > out.wax && wax -f wax out.wax | diff - out.wax
