A numeric (type N) reference may point at a function type the WAT text format
synthesises from an inline (param)/(result) signature (the type-use
abbreviation). Such an implicit type is anonymous: it is rendered inline, while
a reference to an explicit named type keeps its name.

The implicit type at index 1 (() -> f64) is referenced by $void->f64 (type 1)
and rendered inline; $i32->void (type 0) keeps the explicit name $t:

  $ wax func.wat -f wax
  fn f() -> f64 {
      0;
  } // adds implicit type definition
  fn g(i32) {} // reuses explicit type definition
  type t = fn(i32);
  
  fn f_2: t (i32) {} // references the explicit type $t
  fn f_3() -> f64 {
      0;
  } // references the implicit type
  fn check() {
      f_2(0);
      _ = f_3();
  }

It round-trips back to valid WebAssembly:

  $ wax func.wat -f wax | wax -i wax -f wasm -v -o /dev/null && echo OK
  OK

call_indirect against an implicit type renders the cast inline as &fn(..):

  $ wax call-indirect.wat -f wax
  type t = fn(i32);
  fn f() -> f64 {
      0;
  } // mints the implicit type at index 1
  table t: &?func [1, 1];
  elem e: &?func @ t [0] = [f];
  // call_indirect referencing the implicit type by its numeric index
  #[export]
  fn run() -> f64 {
      (t[0] as &?fn() -> f64)();
  }

  $ wax call-indirect.wat -f wax | wax -i wax -f wasm -v -o /dev/null && echo OK
  OK

A `(type N)` *blocktype* may likewise reference an implicit type. The
AST-construction path resolved only declared types, so a bare `(block (type 0))`
naming the inline `(func (param i64) (result i32))` failed to convert; it now
resolves to that signature like the arity path does:

  $ cat > blocktype.wat <<'WAT'
  > (module
  >   (func $g (param i64) (result i32) (i32.const 1))
  >   (func $h (i64.const 2) (block (type 0) (i32.wrap_i64)) (drop)))
  > WAT

  $ wax blocktype.wat -f wax
  fn g(i64) -> i32 {
      1;
  }
  fn h() {
      2;
      do (i64) -> i32 {
          _ as i32;
      }
      _ = _;
  }

  $ wax blocktype.wat -f wax | wax -i wax -f wasm -v -o /dev/null && echo OK
  OK
