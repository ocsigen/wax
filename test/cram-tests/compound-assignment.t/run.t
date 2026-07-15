A compound assignment `x op= e` targets a local or global variable and is
equivalent to `x = x op e`. Typing desugars it (reusing the ordinary binary
operator checks), so lowering emits an ordinary `local.set` / `global.set` over
the corresponding binary operator.

  $ cat > m.wax <<'WAX'
  > let counter: i32 = 0;
  > fn f(x: i32, y: i32) -> i32 {
  >     x += y;
  >     x -= 1;
  >     x *= 2;
  >     x <<= 1;
  >     x /s= 3;
  >     x %u= 5;
  >     x &= 7;
  >     x |= 8;
  >     x ^= 9;
  >     x >>u= 1;
  >     x;
  > }
  > fn tick() {
  >     counter += 1;
  > }
  > fn g(a: f64) -> f64 {
  >     a /= 2.0;
  >     a;
  > }
  > WAX

Lowering to Wasm turns each compound assignment into a get / binop / set:

  $ wax -f wat m.wax
  (global $counter (mut i32) (i32.const 0))
  (func $f (param $x i32) (param $y i32) (result i32)
    (local.set $x (i32.add (local.get $x) (local.get $y)))
    (local.set $x (i32.sub (local.get $x) (i32.const 1)))
    (local.set $x (i32.mul (local.get $x) (i32.const 2)))
    (local.set $x (i32.shl (local.get $x) (i32.const 1)))
    (local.set $x (i32.div_s (local.get $x) (i32.const 3)))
    (local.set $x (i32.rem_u (local.get $x) (i32.const 5)))
    (local.set $x (i32.and (local.get $x) (i32.const 7)))
    (local.set $x (i32.or (local.get $x) (i32.const 8)))
    (local.set $x (i32.xor (local.get $x) (i32.const 9)))
    (local.set $x (i32.shr_u (local.get $x) (i32.const 1)))
    (local.get $x)
  )
  (func $tick
    (global.set $counter (i32.add (global.get $counter) (i32.const 1)))
  )
  (func $g (param $a f64) (result f64)
    (local.set $a (f64.div (local.get $a) (f64.const 2.0)))
    (local.get $a)
  )

The compound form is preserved when reformatting Wax (it does not expand to
`x = x op e`):

  $ wax -f wax m.wax
  let counter: i32 = 0;
  fn f(x: i32, y: i32) -> i32 {
      x += y;
      x -= 1;
      x *= 2;
      x <<= 1;
      x /s= 3;
      x %u= 5;
      x &= 7;
      x |= 8;
      x ^= 9;
      x >>u= 1;
      x;
  }
  fn tick() {
      counter += 1;
  }
  fn g(a: f64) -> f64 {
      a /= 2.0;
      a;
  }

The operator is validated against the variable's type, pointing at the operator
itself. A bitwise operator rejects a float operand:

  $ wax -f wat - <<'WAX'
  > fn f(a: f64) -> f64 { a &= 1.0; a; }
  > WAX
  Error:
    This operator cannot be applied to operands of types 'f64' and 'float'.
   ──➤  -:1:25
  1 │ fn f(a: f64) -> f64 { a &= 1.0; a; }
    ·                         ^^
  2 │ 
  [128]

and an unsigned-agnostic `/` rejects an integer operand (it is float division):

  $ wax -f wat - <<'WAX'
  > fn f(a: i32) -> i32 { a /= 3; a; }
  > WAX
  Error:
    This operator cannot be applied to operands of types 'i32' and 'number'.
   ──➤  -:1:25
  1 │ fn f(a: i32) -> i32 { a /= 3; a; }
    ·                         ^^
  2 │ 
  [128]

Converting Wasm back to Wax recognises `x = x op e` and reconstructs the
compound form. A comparison, or `x` used as the *right* operand, stays a plain
assignment:

  $ wax -i wat -f wax - <<'WAT'
  > (module
  >   (global $g (mut i32) (i32.const 0))
  >   (func $f (param $x i32) (param $y i32) (result i32)
  >     (local.set $x (i32.add (local.get $x) (local.get $y)))
  >     (local.set $x (i32.shr_u (local.get $x) (i32.const 1)))
  >     (global.set $g (i32.mul (global.get $g) (i32.const 2)))
  >     (local.set $x (i32.sub (local.get $y) (local.get $x)))
  >     (local.set $x (i32.lt_s (local.get $x) (local.get $y)))
  >     (local.get $x)))
  > WAT
  let g = 0;
  fn f(x: i32, y: i32) -> i32 {
      x += y;
      x >>u= 1;
      g *= 2;
      x = y - x;
      x = x <s y;
      x;
  }
