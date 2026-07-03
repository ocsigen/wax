A dropped value supplies no expected type, so a bare numeric tree reconstructed
from Wasm re-defaults to i32 on re-parse. Without a width pin, an `i64` all-literal
divisor `2147483648 + 2147483648` (which is `0` in i32 but `4294967296` in i64)
would silently narrow to i32 and turn a `drop`ped `i64.div_u` into a
divide-by-zero **trap** the original module never had. `Drop` now pins the
operand's non-i32 width with an identity cast. Regression: found by the
execution-oracle fuzzer.

  $ cat > m.wat <<'WAT'
  > (module (func (export "f")
  >   (drop (i64.div_u (i64.const 1)
  >     (i64.add (i64.const 2147483648) (i64.const 2147483648))))))
  > WAT

The dropped `i64` tree keeps its width via an `as i64` pin:

  $ wax -i wat -f wax m.wat
  #[export = "f"]
  fn f() {
      _ = (1 /u (2147483648 + 2147483648)) as i64;
  }

and the round-trip back to Wasm still says `i64.div_u`, not a trapping `i32.div_u`:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wat m.wax
  (func $f (export "f")
    (drop
      (i64.div_u (i64.const 1)
        (i64.add (i64.const 2147483648) (i64.const 2147483648))))
  )

An `f32` tree is pinned likewise, while an i32 tree (the re-parse default) and a
tree with a typed anchor (an `i64` local re-pins it) need no cast:

  $ cat > n.wat <<'WAT'
  > (module (func (export "g") (param $x i64)
  >   (drop (f32.add (f32.const 1) (f32.const 2)))
  >   (drop (i32.add (i32.const 1) (i32.const 2)))
  >   (drop (i64.add (i64.const 1) (local.get $x)))))
  > WAT

  $ wax -i wat -f wax n.wat
  #[export = "g"]
  fn g(x: i64) {
      _ = (1 + 2) as f32;
      _ = 1 + 2;
      _ = 1 + x;
  }
