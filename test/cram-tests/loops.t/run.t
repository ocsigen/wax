A 'while' is a leading-test loop and 'do { … } while C;' a trailing-test one —
the readable forms of a 'loop' with an explicit back-edge. A 'while' lowers to
a 'loop' whose body is an 'if' on the test, with the body and a back-'br' in the
'then'; a 'do'-'while' lowers to a 'loop' with the body and a back-'br_if' on the
test. A label-less loop gets a fresh readable label ('loop', then 'loop2', … if
that name is taken by an enclosing label):

  $ wax sum.wax -f wat -v
  (func $sum (param $n i32) (result i32)
    (local $i i32) (local $total i32)
    (local.set $i (i32.const 0))
    (local.set $total (i32.const 0))
    (loop $loop
      (if (i32.lt_s (local.get $i) (local.get $n))
        (then
          (local.set $total (i32.add (local.get $total) (local.get $i)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop))))
    (loop $loop
      (local.set $total (i32.sub (local.get $total) (i32.const 1)))
      (br_if $loop (i32.gt_s (local.get $total) (i32.const 0))))
    (local.get $total)
  )

The 'while' and 'do'-'while' keywords are preserved when formatting Wax:

  $ wax sum.wax -f wax
  fn sum(n: i32) -> i32 {
      let i: i32 = 0;
      let total: i32 = 0;
      while i <s n {
          total = total + i;
          i = i + 1;
      }
      do {
          total = total - 1;
      } while total >s 0;
      total;
  }

Decompiling recovers the loops from that shape, so they survive a round trip
through WAT:

  $ wax sum.wax -f wat | wax -i wat -f wax
  fn sum(n: i32) -> i32 {
      let i = 0;
      let total = 0;
      while i <s n {
          total = total + i;
          i = i + 1;
      }
      do {
          total = total - 1;
      } while total >s 0;
      total;
  }

A branch back to the loop from inside the body is a 'continue', so the loop
label is kept (here renamed by decompilation); a label-less loop round-trips
label-less:

  $ wax continue.wax -f wat | wax -i wat -f wax
  fn f(n: i32) -> i32 {
      let i = 0;
      'top: while i <s n {
          i = i + 1;
          if i == 3 {
              br 'top;
          }
          n = n - 1;
      }
      n;
  }

The synthetic label avoids every enclosing label, so a 'br' to an enclosing
loop or block keeps targeting it: the outer 'do' block is '$loop', so the two
label-less inner loops become '$loop2' and '$loop3' and the body's 'br 'loop'
still exits the outer block:

  $ wax nested.wax -f wat
  (func $f (param $n i32) (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $loop
      (loop $loop2
        (if (i32.lt_s (local.get $i) (local.get $n))
          (then
            (loop $loop3
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br_if $loop3 (i32.lt_s (local.get $i) (i32.const 3))))
            (br $loop)
            (br $loop2)))))
    (local.get $i)
  )

A 'do'-'while' test must be an 'i32':

  $ wax err_dowhile_type.wax -f wat -v
  Error: This instruction has type f64 but is expected to have type i32.
   ──➤  err_dowhile_type.wax:4:13
  2 │     do {
  3 │         nop;
  4 │     } while x;
    ·             ^
  5 │ }
  6 │ 
  [128]

A 'do'-'while' loop is void, so it cannot carry a block type:

  $ wax err_dowhile_blocktype.wax -f wat -v
  Error: A do-while loop cannot have a block type.
  
   ──➤  err_dowhile_blocktype.wax:2:5
  1 │ fn g() {
  2 │     do (i32) {
    ·     ^^^^^^^^^^^
  3 │         nop;
    · ^^^^^^^^^^^^^
  4 │     } while 1;
    · ^^^^^^^^^^^^^^
  5 │ }
  6 │ 
  [123]
