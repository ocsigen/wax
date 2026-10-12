`--try-table` rewrites the legacy exception-handling instructions (`try` with
`catch`/`catch_all`) into the standard `try_table`: one block per handler, the
first innermost, and a join block carrying the try's label and result. A
handler but the last exits to the join (unless it already diverges); the body's
completion does too. Numeric branch depths are adjusted for the inserted blocks,
and the try's parameters are passed through the handler blocks.

  $ wax --try-table legacy.wat -f wat
  (tag $a (param i32))
  (tag $b (param i32 i64))
  (tag $c)
  
  ;; numeric branches from the body (to the try, past it) and from handlers
  (func $depths (param i32) (result i32)
    block (result i32)
      block (result i32)
        block
          block (result i32 i64)
            block (result i32)
              try_table (result i32)
                (catch $a 0)
                (catch $b 1)
                (catch_all 2)
                i32.const 100
                local.get 0
                br_table 4 5 4
              end
              br 3
            end
            local.get 0
            br_if 3
            i32.const 1
            i32.add
            br 2
          end
          i32.wrap_i64
          i32.add
          br 1
        end
        i32.const 7
      end
    end
  )
  
  ;; block parameters, a catch_all only, and no handler at all
  (func $params (param i32) (result i32)
    local.get 0
    i32.const 3
    block (param i32 i32) (result i32)
      block (param i32 i32)
        try_table (param i32 i32) (result i32)
          (catch_all 0)
          i32.add
        end
        br 1
      end
      i32.const 9
    end
    try_table
    end
  )
  
  ;; nested: the inner try's handler branches to the outer try
  (func $nested (param i32) (result i32)
    block $outer (result i32)
      block (result i32)
        try_table (result i32)
          (catch $a 0)
          block (result i32)
            block
              try_table (result i32)
                (catch $c 0)
                local.get 0
              end
              br 1
            end
            i32.const 77
            br $outer
          end
        end
        br $outer
      end
    end
  )

The rewritten module is valid, and so is one decoded from a binary (where every
label is numeric).

  $ wax --try-table legacy.wat -f wat -o rewritten.wat
  $ wax -v rewritten.wat -f wasm -o /dev/null
  $ wax legacy.wat -f wasm -o legacy.wasm
  $ wax --try-table legacy.wasm -f wat -o decoded.wat
  $ wax -v decoded.wat -f wasm -o /dev/null
  $ wax --try-table legacy.wasm -f wasm -o rewritten.wasm
  $ wax -v rewritten.wasm -f wat | grep -c 'try_table'
  5

Decompiling to Wax, the ladder is recovered as a structured try where the
decompiler recognizes its shape (it does not when a handler's code gets folded
into an operand, or when the try takes parameters).

  $ wax --try-table legacy.wat -f wax
  tag a(i32);
  tag b(i32, i64);
  tag c();
  
  // numeric branches from the body (to the try, past it) and from handlers
  fn depths(x: i32) -> i32 {
      'l: do {
          'l_2: do {
              'l_3: do {
                  'l_4: do () -> (i32, i64) {
                      br 'l_2
                          (br_if 'l
                               ('l_5: do {
                                    br 'l_2
                                        try i32 {
                                            br_table [ 'l_2, 'l, else 'l_2 ] (100, x);
                                        } catch [ a -> 'l_5, b -> 'l_4, _ -> 'l_3];
                                }, x)) + 1;
                  }
                  br 'l_2 _ + _ as i32;
              }
              7;
          }
      }
  }
  
  // block parameters, a catch_all only, and no handler at all
  fn params(x: i32) -> i32 {
      x;
      3;
      'l: do (i32, i32) -> i32 {
          'l_2: do (i32, i32) {
              try (i32, i32) -> i32 {
                  _ + _;
              } catch [ _ -> 'l_2]
              br 'l _;
          }
          9;
      }
      try {} catch []
  }
  
  // nested: the inner try's handler branches to the outer try
  fn nested(x: i32) -> i32 {
      'outer: try {
          try {
              x;
          } catch {
              c => {
                  br 'outer 77;
              }
          }
      } catch {
          a => {}
      }
  }

On a Wax-to-Wax conversion, each `try_legacy` becomes the structured `try`: an
arm but the last gets a branch to the try's label carrying the try's result,
one `_` per value (the typer tells how many an unannotated try yields). A try
that needs such a branch and has no label gets a fresh one, distinct from every
label of its function.

  $ wax --try-table legacy.wax -f wax
  tag a(i32);
  tag b(i32, i64);
  tag c();
  
  // An unannotated try whose result type comes from its context; the dead
  // literal after the throw takes that type too.
  fn inferred(x: f32) -> f32 {
      'join: try {
          throw c();
          0;
      } catch {
          c => {
              x;
              br 'join _;
          }
          _ => {
              1;
          }
      }
  }
  
  // The fresh label avoids the function's own labels; a diverging arm needs no
  // exit; several values leave through one branch.
  fn labels(k: i32) -> (i32, i64) {
      'join: loop {
          'join1: try {
              if k {
                  br 'join;
              }
          } catch {
              a => {
                  _ = _;
                  return (1, 2 as i64);
              }
              c => {
                  br 'join1;
              }
              _ => {}
          }
      }
      'join2: try () -> (i32, i64) {
          (k, 3 as i64);
      } catch {
          b => {
              _;
              br 'join2 (_, _);
          }
          _ => {
              (0, 4 as i64);
          }
      }
  }
  
  // In expression position, with a pass-through arm.
  fn expr(k: i32) -> i32 {
      k
          + 'join: try i32 {
                k;
            } catch {
                a => {
                    br 'join _;
                }
                _ => {
                    0;
                }
            };
  }

  $ wax --try-table legacy.wax -f wax -o structured.wax
  $ wax -v structured.wax -f wasm -o /dev/null

The rewrite also applies when compiling Wax to Wasm.

  $ wax --try-table legacy.wax -f wat | grep -c 'try_table'
  4

A structured try takes no parameters, so a `try_legacy` that does has no
counterpart.

  $ wax --try-table params.wax -f wax
  Error: This legacy try takes parameters, which a structured try cannot take.
   ──➤  params.wax:3:5
  1 │ fn f(x: i32) -> i32 {
  2 │     x;
  3 │     try_legacy (i32) -> i32 { _ + 1; } catch { _ => { 0; } }
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ }
  5 │ 
  Hint: Pass the values to its body through locals instead.
  [128]

A same-format WAT conversion is not validated first: an unbound tag is
reported, not a crash.

  $ wax --try-table unbound.wat -f wat
  Error: This tag is unbound.
   ──➤  unbound.wat:4:11
  2 │   (func
  3 │     try
  4 │     catch $nope
    ·           ^^^^^
  5 │     end))
  6 │ 
  [128]

A tag declared in both branches of a conditional resolves when the branches
agree on its payload; otherwise the conditionals must be resolved first.

  $ wax --try-table cond_same.wat -f wat
  (@if $wide (@then (tag $e (param i32))) (@else (tag $e (param i32))))
  (func
    block
      block
        block (result i32)
          try_table
            (catch $e 0)
            (catch_all 1)
          end
          br 2
        end
        drop
        br 1
      end
    end
  )
  $ wax --try-table cond.wat -f wat
  Error:
    This tag is declared differently in the branches of a conditional
    annotation.
   ──➤  cond.wat:7:11
  5 │   (func
  6 │     try
  7 │     catch $e
    ·           ^^
  8 │       drop
  9 │     catch_all
  Hint: Resolve the conditionals with -D/--define.
  [128]
  $ wax --try-table -D wide=false cond.wat -f wat
  (tag $e (param i32))
  (func
    block
      block
        block (result i32)
          try_table
            (catch $e 0)
            (catch_all 1)
          end
          br 2
        end
        drop
        br 1
      end
    end
  )
