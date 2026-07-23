The offset/align/lane immediates of a memory access are labelled arguments.
They come after the positional stack operands, in any order; the decompiler
prints offset when non-zero and align when non-natural.

  $ cat > ok.wax <<'EOF'
  > memory m: i32 [1];
  > fn f(p: i32, v: i32) {
  >     m.store32(p, v, offset: 16, align: 1);
  >     m.store32(p, v, align: 1, offset: 16);
  >     m.atomic_store32(p, v, offset: 8);
  > }
  > fn g(p: i32, v: v128) -> v128 {
  >     m.load8_lane(p, v, lane: 3, offset: 16);
  > }
  > fn h(p: i32) -> i32 {
  >     become h(m.load32(p, offset: 4));
  > }
  > EOF
  $ wax -f wat ok.wax
  (memory $m 1)
  (func $f (param $p i32) (param $v i32)
    (i32.store $m offset=16 align=1 (local.get $p) (local.get $v))
    (i32.store $m offset=16 align=1 (local.get $p) (local.get $v))
    (i32.atomic.store $m offset=8 (local.get $p) (local.get $v))
  )
  (func $g (param $p i32) (param $v v128) (result v128)
    (v128.load8_lane $m offset=16 3 (local.get $p) (local.get $v))
  )
  (func $h (param $p i32) (result i32)
    (return_call $h (i32.load $m offset=4 (local.get $p)))
  )

A wat module with memarg immediates decompiles to the labelled syntax, offset
and align independently of each other:

  $ cat > mem.wat <<'EOF'
  > (module
  >   (memory $m 1)
  >   (func $f (param $p i32) (param $v v128)
  >     (i32.store offset=4 (local.get $p) (i32.const 0))
  >     (i32.store align=1 (local.get $p) (i32.const 0))
  >     (v128.store8_lane offset=2 3 (local.get $p) (local.get $v))))
  > EOF
  $ wax -i wat -f wax mem.wat
  memory m: i32 [1];
  fn f(p: i32, v: v128) {
      m.store32(p, 0, offset: 4);
      m.store32(p, 0, align: 1);
      m.store8_lane(p, v, lane: 3, offset: 2);
  }

A label anywhere else is an error; so are an unknown or duplicated label, a
positional argument after a labelled one, and a non-constant payload:

  $ cat > bad.wax <<'EOF'
  > memory m: i32 [1];
  > fn a(x: i32) -> i32 {
  >     a(offset: 3);
  > }
  > fn b(p: i32) -> i32 {
  >     m.load32(p, ofset: 4);
  > }
  > fn c(p: i32) -> i32 {
  >     m.load32(p, offset: 4, offset: 5);
  > }
  > fn d(v: v128) -> i32 {
  >     v.extract_lane_s_i8x16(lane: 3);
  > }
  > fn e(offset: i32) -> i32 {
  >     m.load32(offset: 4, offset);
  > }
  > fn f(p: i32, x: i32) -> i32 {
  >     m.load32(p, offset: x);
  > }
  > EOF
  $ wax check bad.wax
  Error:
    Labelled arguments are only allowed for the 'offset', 'align' and 'lane'
    immediates of a memory access.
   ──➤  bad.wax:3:7
  1 │ memory m: i32 [1];
  2 │ fn a(x: i32) -> i32 {
  3 │     a(offset: 3);
    ·       ^^^^^^^^^
  4 │ }
  5 │ fn b(p: i32) -> i32 {
  Error: Unknown argument label 'ofset'.
   ──➤  bad.wax:6:17
  4 │ }
  5 │ fn b(p: i32) -> i32 {
  6 │     m.load32(p, ofset: 4);
    ·                 ^^^^^
  7 │ }
  8 │ fn c(p: i32) -> i32 {
  Hint: Did you mean 'offset'?
  Error: The argument label 'offset' is given several times.
    ──➤  bad.wax:9:28
   7 │ }
   8 │ fn c(p: i32) -> i32 {
   9 │     m.load32(p, offset: 4, offset: 5);
     ·                            ^^^^^^
     ·                 ^^^^^^ previously given here
  10 │ }
  11 │ fn d(v: v128) -> i32 {
  Error:
    Labelled arguments are only allowed for the 'offset', 'align' and 'lane'
    immediates of a memory access.
    ──➤  bad.wax:12:28
  10 │ }
  11 │ fn d(v: v128) -> i32 {
  12 │     v.extract_lane_s_i8x16(lane: 3);
     ·                            ^^^^^^^
  13 │ }
  14 │ fn e(offset: i32) -> i32 {
  Error: A positional argument cannot follow a labelled argument.
    ──➤  bad.wax:15:25
  13 │ }
  14 │ fn e(offset: i32) -> i32 {
  15 │     m.load32(offset: 4, offset);
     ·                         ^^^^^^
  16 │ }
  17 │ fn f(p: i32, x: i32) -> i32 {
  Error: Only integer literals are allowed here.
    ──➤  bad.wax:18:25
  16 │ }
  17 │ fn f(p: i32, x: i32) -> i32 {
  18 │     m.load32(p, offset: x);
     ·                         ^
  19 │ }
  20 │ 
  [128]

A SIMD lane access needs its lane immediate:

  $ cat > nolane.wax <<'EOF'
  > memory m: i32 [1];
  > fn f(p: i32, v: v128) -> v128 {
  >     m.load8_lane(p, v, offset: 16);
  > }
  > EOF
  $ wax check nolane.wax
  Error: This memory access needs a 'lane:' immediate (e.g. 'lane: 0').
   ──➤  nolane.wax:3:7
  1 │ memory m: i32 [1];
  2 │ fn f(p: i32, v: v128) -> v128 {
  3 │     m.load8_lane(p, v, offset: 16);
    ·       ^^^^^^^^^^
  4 │ }
  5 │ 
  [128]

The pre-labelled positional immediates get a targeted migration error (and
still validate, so a real range error is not masked):

  $ cat > positional.wax <<'EOF'
  > memory m: i32 [1];
  > fn f(p: i32) -> i32 {
  >     m.load32(p, 1, 16);
  > }
  > fn g(p: i32, v: v128) -> v128 {
  >     m.load8_lane(p, v, 16);
  > }
  > EOF
  $ wax check positional.wax
  Error:
    The static immediates of a memory access must be labelled, e.g.
    'm.load32(..., offset: 16, align: 1)'.
   ──➤  positional.wax:3:17
  1 │ memory m: i32 [1];
  2 │ fn f(p: i32) -> i32 {
  3 │     m.load32(p, 1, 16);
    ·                 ^
  4 │ }
  5 │ fn g(p: i32, v: v128) -> v128 {
  Error:
    The static immediates of a memory access must be labelled, e.g.
    'm.load8_lane(..., lane: 0, offset: 16)'.
   ──➤  positional.wax:6:24
  4 │ }
  5 │ fn g(p: i32, v: v128) -> v128 {
  6 │     m.load8_lane(p, v, 16);
    ·                        ^^
  7 │ }
  8 │ 
  Error: The lane index should be less than 16.
   ──➤  positional.wax:6:24
  4 │ }
  5 │ fn g(p: i32, v: v128) -> v128 {
  6 │     m.load8_lane(p, v, 16);
    ·                        ^^
  7 │ }
  8 │ 
  [128]
