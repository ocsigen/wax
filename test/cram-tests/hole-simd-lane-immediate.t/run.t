A SIMD lane intrinsic written as a method carries its lane index as a static
immediate, e.g. `_.extract_lane_u_i8x16(4)`. When the receiver is a hole '_' (a
value taken from the enclosing operand stack), the lane immediate must not be
mistaken for a value pushed *before* the hole: it is part of the opcode, not a
stack operand. This previously failed to decompile with "This expression occurs
before a hole '_'." Regression: found by the differential-validation fuzzer.

  $ cat > lane.wat <<'WAT'
  > (module
  >   (func (export "f") (param v128) (result i32)
  >     local.get 0
  >     (block (param v128) (result i32)
  >       i8x16.extract_lane_u 4)))
  > WAT

The receiver appears as a hole and the lane index stays an immediate argument:

  $ wax -i wat -f wax lane.wat
  #[export = "f"]
  fn f(x: v128) -> i32 {
      x;
      do (v128) -> i32 {
          _.extract_lane_u_i8x16(4);
      }
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax lane.wat -o lane.wax && wax -i wax -f wasm lane.wax -o /dev/null --validate

The same applies to a receiver-first scalar intrinsic method whose receiver is a
hole, e.g. `_.copysign(c)`: the operand `c` follows the receiver on the stack, so
it must not be reported as occurring before the receiver hole.

  $ cat > cs.wat <<'WAT'
  > (module
  >   (func (export "f") (param f64) (result f64)
  >     local.get 0
  >     (block (param f64) (result f64)
  >       f64.const 0x1p-1
  >       f64.copysign)))
  > WAT

  $ wax -i wat -f wax cs.wat
  #[export = "f"]
  fn f(x: f64) -> f64 {
      x;
      do (f64) -> f64 {
          _.copysign(0x1p-1);
      }
  }

  $ wax -i wat -f wax cs.wat -o cs.wax && wax -i wax -f wasm cs.wax -o /dev/null --validate
