A 'dispatch' is a multi-way branch — the readable form of a 'br_table' jump
table. The bracket maps an index to a case (with 'else' the default), and each
arm gives that case's body. It lowers to one nested block per case, with the
'br_table' in the innermost block and each case body just after its block, so
reaching a case runs its body (and falls through into the next arm listed,
unless it branches away — here each case returns). Arms are written in that
fall-through order, the reverse of the bracket's index order:

  $ wax classify.wax -f wat -v
  (func $classify (param $x i32) (result i32)
    (block $zero
      (block $one
        (block $two
          (block $big (br_table $zero $one $two $big (local.get $x)))
          (return (i32.const 99)))
        (return (i32.const 30)))
      (return (i32.const 20)))
    (return (i32.const 10))
  )

The 'dispatch' keyword is preserved when formatting Wax:

  $ wax classify.wax -f wax
  fn classify(x: i32) -> i32 {
      dispatch x [ 'zero, 'one, 'two, else 'big ] {
          'big: {
              return 99;
          }
          'two: {
              return 30;
          }
          'one: {
              return 20;
          }
          'zero: {
              return 10;
          }
      }
  }

Decompiling recovers the 'dispatch' from that block shape — every case an arm —
so it survives a round trip through WAT:

  $ wax classify.wax -f wat | wax -i wat -f wax
  fn classify(x: i32) -> i32 {
      dispatch x [ 'zero, 'one, 'two, else 'big ] {
          'big: {
              return 99;
          }
          'two: {
              return 30;
          }
          'one: {
              return 20;
          }
          'zero: {
              return 10;
          }
      }
  }

Case labels must be distinct:

  $ wax err_dup.wax -f wat -v
  Error: This dispatch has several cases named 'a'.
   ──➤  err_dup.wax:5:9
  3 │         'a: { return; }
  4 │         'b: { return; }
  5 │         'a: { return; }
    ·         ^^
  6 │     }
  7 │ }
  [128]

The index must be an 'i32':

  $ wax err_index.wax -f wat -v
  Error: This instruction has type 'f64' but is expected to have type 'i32'.
   ──➤  err_index.wax:3:18
  1 │ fn g(x: f64) {
  2 │     'out: do {
  3 │         dispatch x ['a, else 'out] {
    ·                  ^
  4 │             'a: { nop; }
  5 │         }
  [128]

A label-less `while` synthesises a fresh `loop` label that must avoid the arm
labels of a `dispatch` in its body, or the two collide on a shared `'loop` name
(the synthesised loop takes `loop2` instead):

  $ cat > while_loop.wax <<'WAX'
  > fn f(x: i32) {
  >     while x != 0 {
  >         dispatch x ['loop, else 'done] {
  >             'done: { }
  >             'loop: { }
  >         }
  >     }
  > }
  > WAX

  $ wax while_loop.wax -f wat
  (func $f (param $x i32)
    (loop $loop2
      (if (i32.ne (local.get $x) (i32.const 0))
        (then
          (block $loop (block $done (br_table $loop $done (local.get $x))))
          (br $loop2))))
  )
