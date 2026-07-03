A 'while' is a leading-test loop — the readable form of a 'loop' whose body is
an 'if' on the test, with the body and a back-'br' in the 'then'. A trailing-test
loop (the body, then a back-'br_if' on the test) has no leading-'while' form, so
it is written and kept as a plain 'loop'. A label-less loop gets a fresh readable
label ('loop', then 'loop2', … if that name is taken by an enclosing label):

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

The 'while' keyword is preserved when formatting Wax; the trailing-test loop
stays a plain 'loop':

  $ wax sum.wax -f wax
  fn sum(n: i32) -> i32 {
      let i: i32 = 0;
      let total: i32 = 0;
      while i <s n {
          total = total + i;
          i = i + 1;
      }
      'loop: loop {
          total = total - 1;
          br_if 'loop total >s 0;
      }
      total;
  }

Decompiling recovers the 'while' from that shape, so it survives a round trip
through WAT; the trailing-test loop round-trips as the plain 'loop' it already
is:

  $ wax sum.wax -f wat | wax -i wat -f wax
  fn sum(n: i32) -> i32 {
      let i = 0;
      let total = 0;
      while i <s n {
          total += i;
          i += 1;
      }
      'loop: loop {
          total -= 1;
          br_if 'loop total >s 0;
      }
      total;
  }

A branch back to the loop from inside the body is a 'continue', so the loop
label is kept (here renamed by decompilation); a label-less loop round-trips
label-less:

  $ wax continue.wax -f wat | wax -i wat -f wax
  fn f(n: i32) -> i32 {
      let i = 0;
      'top: while i <s n {
          i += 1;
          if i == 3 {
              br 'top;
          }
          n -= 1;
      }
      n;
  }

The synthetic label avoids every enclosing label, so a 'br' to an enclosing
loop or block keeps targeting it: the outer 'do' block is '$loop' and the inner
trailing-test loop keeps its '$inner' label, so the label-less 'while' becomes
'$loop2' and the body's 'br 'loop' still exits the outer block:

  $ wax nested.wax -f wat
  (func $f (param $n i32) (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $loop
      (loop $loop2
        (if (i32.lt_s (local.get $i) (local.get $n))
          (then
            (loop $inner
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br_if $inner (i32.lt_s (local.get $i) (i32.const 3))))
            (br $loop)
            (br $loop2)))))
    (local.get $i)
  )
