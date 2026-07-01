`array.len` (the `.length()` method) accepts any subtype of `(ref null array)`,
including the bottom reference `&none` (which is below `array`) and the abstract
array reference. Unlike `fill`/`copy`/`init`, it needs no concrete element type,
so a bottom-reference receiver is fine — it just traps at run time.

  $ cat > none.wax <<'EOF'
  > #[export = "f"]
  > fn f(x: &none) -> i32 {
  >     x.length();
  > }
  > EOF

  $ wax -i wax -f wat none.wax --validate
  (func $f (export "f") (param $x (ref none)) (result i32)
    (array.len (local.get $x))
  )

`fill`/`copy`/`init` still require a concrete array element type, so a `&none`
receiver is rejected there:

  $ cat > fill.wax <<'EOF'
  > #[export = "f"]
  > fn f(x: &none) {
  >     x.fill(0, 0, 0);
  > }
  > EOF

  $ wax check fill.wax
  Error: Expected array type.
   ──➤  fill.wax:3:5
  1 │ #[export = "f"]
  2 │ fn f(x: &none) {
  3 │     x.fill(0, 0, 0);
    ·     ^
  4 │ }
  5 │ 
  [123]
