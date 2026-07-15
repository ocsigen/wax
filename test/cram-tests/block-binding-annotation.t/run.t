When a block is the initializer of a binding, the binding's type annotation is
kept only when it does real work — i.e. when the block's value would not already
have that type on its own. A value that is naturally the expected type lets the
annotation drop; a value that would default differently (a bare literal) keeps
it:

  $ wax cases.wat -f wax
  tag e();
  // The do block's value (inner * inner) is naturally i32 — the binding's i32
  // annotation is redundant and drops.
  #[export]
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
  #[export]
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
  #[export]
  fn br_drops(c: i32, n: i64) -> i64 {
      let x =
          'l: do {
              if c {
                  br 'l 42;
              }
              n;
          };
      x;
  }
  // A try's catch handler likewise produces a subtype of the result, so it does
  // not change the inference: the body's fall-through ($n) is already i64, so
  // the annotation drops.
  #[export]
  fn try_drops(n: i64) -> i64 {
      let x =
          try_legacy {
              n;
          } catch {
              e => {
                  0;
              }
          };
      x;
  }
  // The value reaches the block only by a branch to its label; the fall-through
  // diverges (unreachable), so there is nothing on the stack to read. The
  // branched value ($n, already i64) is still collected at its natural type, so
  // the annotation drops anyway.
  #[export]
  fn divergent_drops(n: i64) -> i64 {
      let x =
          'l: do {
              br 'l n;
              unreachable;
          };
      x;
  }
  // The trailing value is itself a nested block; it synthesizes its own type
  // ($n, i64) rather than being forced to the context, so the annotation drops.
  #[export]
  fn nested_block_drops(n: i64) -> i64 {
      let x =
          do {
              do {
                  n;
              }
          };
      x;
  }
  // The try's body diverges (it returns), so the value comes only from the catch
  // handler; that handler's value ($n, already i64) is collected too, so the
  // annotation drops.
  #[export]
  fn try_handler_drops(n: i64) -> i64 {
      let x =
          try_legacy {
              return n;
          } catch {
              e => {
                  n;
              }
          };
      x;
  }
