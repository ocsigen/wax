When converting from Wasm, an expression that produces several values (such as
a multi-value call) is emitted as a bare statement whose results are then peeled
off by a run of `let x = _` declarations. That run is folded back into a single
multi-binding `let (..) = expr`, the inverse of how such a `let` lowers. The
length of the run that is folded is the producer's result arity, taken from the
inferred type, so values sitting below it on the stack are never absorbed.

  $ wax -i wat -f wax recover.wat
  fn parse(x: i32) -> (i32, i32, i32, i32) {
      1;
      2;
      3;
      4;
  }
  
  // A multi-value call whose results are peeled off by a run of local.set
  // folds back into a single multi-binding let.
  fn basic(x: i32) -> i32 {
      let (a, b, c, d) = parse(x);
      a;
  }
  
  // A discarded result becomes a `_` binding.
  fn dropped() -> i32 {
      let (a, _, _, c) = parse(0);
      a + c;
  }
  
  // The run consumed is exactly the call's arity: with a value already on the
  // stack below the call, the extra local.set draws from it, not the call, so
  // only the two call results fold.
  fn arity(p: i32) -> i32 {
      p;
      let (b, a) = two();
      let c = _;
      a + b + c;
  }
  
  fn two() -> (i32, i32) {
      10;
      20;
  }
