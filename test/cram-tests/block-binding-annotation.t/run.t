When a block is the initializer of a binding, the binding's type annotation is
kept only when it does real work — i.e. when the block's value would not already
have that type on its own. A value that is naturally the expected type lets the
annotation drop; a value that would default differently (a bare literal) keeps
it:

  $ wax cases.wat -f wax
  tag e();
  // The do block's value (inner * inner) is naturally i32 — the binding's i32
  // annotation is redundant and drops.
  #[export = "drops"]
  fn drops(x: i32) -> i32 {
      let outer =
          do {
              let inner = x + 1;
              inner * inner;
          };
      outer;
  }
  // The do block's value is a bare i64 literal, which would default to i32 on
  // its own — the i64 annotation is doing real work, so it is kept.
  #[export = "keeps"]
  fn keeps() -> i64 {
      let x: i64 =
          do {
              42;
          };
      x;
  }
  // The value can also arrive by a branch to the block's label; that delivered
  // value is still a subtype of the result, so when the fall-through ($n) is
  // already i64 the annotation drops anyway.
  #[export = "br_drops"]
  fn br_drops(c: i32, n: i64) -> i64 {
      let x =
          'l_2: do {
              if c {
                  br 'l_2 42;
              }
              n;
          };
      x;
  }
  // A try's catch handler likewise produces a subtype of the result, so it does
  // not change the inference: the body's fall-through ($n) is already i64, so
  // the annotation drops.
  #[export = "try_drops"]
  fn try_drops(n: i64) -> i64 {
      let x =
          try {
              n;
          } catch {
              e => {
                  0;
              }
          };
      x;
  }
