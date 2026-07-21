A 'match' is a multi-way type test — the readable form of the nested type-test
ladder that hand-written GC code uses. Each arm tests the scrutinee against a
reference type (optionally binding the narrowed value) or 'null', and the
optional '_' arm is the default. The scrutinee is evaluated once and threaded
through a 'br_on_cast'/'br_on_null' chain in the innermost block; each test
branches out to its arm's block carrying the narrowed value, an arm body must
leave the 'match' (here each returns), and the default is the trailing code past
the outer escape block:

  $ wax classify.wax -f wat -v
  (type $pair (struct (field $a i32) (field $b i32)))
  (type $ints (array (mut i32)))
  
  (func $classify (param $v eqref) (result i32)
    (local $a (ref $ints)) (local $p (ref $pair))
    (block $default
      (block $arm_2
        (local.set $a
          (block $arm_1 (result (ref $ints))
            (local.set $p
              (block $arm (result (ref $pair))
                (drop
                  (br_on_null $arm_2
                    (br_on_cast $arm_1 eqref (ref $ints)
                      (br_on_cast $arm eqref (ref $pair) (local.get $v)))))
                (br $default)))
            (return
              (i32.add (struct.get $pair $a (local.get $p))
                (struct.get $pair $b (local.get $p))))))
        (return (array.len (local.get $a))))
      (return (i32.const -1)))
    (return (i32.const 0))
  )


The 'match' keyword is preserved when formatting Wax:

  $ wax classify.wax -f wax
  type pair = { a: i32, b: i32 };
  type ints = [mut i32];
  
  fn classify(v: &?eq) -> i32 {
      match v {
          p: &pair => {
              return p.a + p.b;
          }
          a: &ints => {
              return a.length();
          }
          null => {
              return -1;
          }
          _ => {
              return 0;
          }
      }
  }


Decompiling recovers the 'match' from that nested block ladder — every test an
arm — so it survives a round trip through WAT:

  $ wax classify.wax -f wat | wax -i wat -f wax
  type pair = { a: i32, b: i32 };
  type ints = [mut i32];
  
  fn classify(v: &?eq) -> i32 {
      match v {
          p: &pair => {
              return p.a + p.b;
          }
          a: &ints => {
              return a.length();
          }
          null => {
              return -1;
          }
          _ => {
              return 0;
          }
      }
  }


Because the scrutinee is evaluated once (threaded through the chain rather than
re-read per arm), it may be a side-effecting expression — the call here is
emitted a single time:

  $ wax side_effect.wax -f wat -v
  (type $pair (struct (field $a i32) (field $b i32)))
  
  (func $get (result eqref) (ref.i31 (i32.const 0)))
  
  (func $f (result i32)
    (local $p (ref $pair))
    (block $default
      (local.set $p
        (block $arm (result (ref $pair))
          (drop (br_on_cast $arm eqref (ref $pair) (call $get)))
          (br $default)))
      (return (struct.get $pair $a (local.get $p))))
    (return (i32.const 0))
  )

The default arm is required (like a `dispatch`'s `else`):

  $ wax err_no_default.wax -f wat -v
  Error: Expecting a match default.
   ──➤  err_no_default.wax:4:5
  2 │     match v {
  3 │         &eq => { return; }
  4 │     }
    ·     ^
  5 │ }
  6 │ 
  [128]

The scrutinee must be a reference:

  $ wax err_scrut.wax -f wat -v
  Error: Expected reference.
   ──➤  err_scrut.wax:2:11
  1 │ fn g(x: i32) {
  2 │     match x {
    ·           ^
  3 │         &eq => { return; }
  4 │         null => { return; }
  [128]

A `match` synthesises `arm`/`default` block labels that must avoid a label the
user defined inside an arm body, or they collide (the synthesised arm takes
`arm1` instead):

  $ cat > match_arm.wax <<'WAX'
  > type ints = [mut i32];
  > fn f(v: &?eq) -> i32 {
  >     match v {
  >         a: &ints => { 'arm: do { br 'arm; } return a.length(); }
  >         _ => { return 0; }
  >     }
  > }
  > WAX

  $ wax match_arm.wax -f wat
  (type $ints (array (mut i32)))
  (func $f (param $v eqref) (result i32)
    (local $a (ref $ints))
    (block $default
      (local.set $a
        (block $arm1 (result (ref $ints))
          (drop (br_on_cast $arm1 eqref (ref $ints) (local.get $v)))
          (br $default)))
      (block $arm (br $arm))
      (return (array.len (local.get $a))))
    (return (i32.const 0))
  )
