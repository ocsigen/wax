An untyped `select` of holes (a dead-code `select` with no result type and no
concrete arm) re-parses type-ADAPTIVELY: `(_?_:_)` takes the i32 default, exactly
like a bare hole. It is pushed with a `None` width tag, though, which the width
eraser's anchor test would otherwise read as a grounded anchor — so a
width-sensitive consumer whose other operand is a hole (`i64.shr_u`, a
comparison) would skip pinning that sibling and the shift would lose its `i64`
width on re-parse (`_ >>u (_?_:_)` re-parses as `i32.shr_u`). `from_wasm`'s
`is_anchor` excludes an adaptive select-of-holes, so the sibling is pinned. A
concrete-arm select (two locals) is a genuine width anchor and still grounds the
op with no sibling pin.

  $ cat > m.wat <<'WAT'
  > (module
  >   (func $shr_sel unreachable select i64.shr_u drop)
  >   (func $cmp_sel unreachable select i64.lt_s drop)
  >   (func $shr_i32 unreachable select i32.shr_u drop)
  >   (func $shr_anchor (param i64 i64 i32) unreachable local.get 0 local.get 1 local.get 2 select i64.shr_u drop))
  > WAT

The sibling hole is pinned to the opcode width against an adaptive select, never
against a concrete-arm select (an anchor), and never for an i32 op:

  $ wax -i wat -f wax --faithful m.wat
  fn shr_sel() {
      unreachable;
      _ = _ as i64 >>u (_?_:_);
  }
  fn cmp_sel() {
      unreachable;
      _ = _ as i64 <s (_?_:_);
  }
  fn shr_i32() {
      unreachable;
      _ = _ >>u (_?_:_);
  }
  fn shr_anchor(x: i64, x_2: i64, x_3: i32) {
      unreachable;
      _ = _ >>u (x_3?x:x_2);
  }

Round-tripping back to Wasm recovers every op at its original width (the shift
against an adaptive select stays `i64.shr_u`, not `i32.shr_u`):

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wat m.wax
  (func $shr_sel (unreachable) (drop (i64.shr_u (select))))
  (func $cmp_sel (unreachable) (drop (i64.lt_s (select))))
  (func $shr_i32 (unreachable) (drop (i32.shr_u (select))))
  (func $shr_anchor (param $x i64) (param $x_2 i64) (param $x_3 i32)
    (unreachable)
    (drop (i64.shr_u (select (local.get $x) (local.get $x_2) (local.get $x_3))))
  )
