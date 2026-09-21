Regression (wasm-smith fuzzer, reduced): a block-like statement whose value is
left on the stack must keep its own result type through `simplify`.

Two annotations are redundant on their own and were both dropped: the block's
`&?any` result, because the `ref.cast anyref` wrapping it pinned the same type,
and then the cast, because the block already had that type. What was left is a
bare `do { … }` statement, and nothing in statement position re-supplies the
result on a re-parse — so the body's value was stranded ("This value remains on
the stack") and the module no longer recompiled. The block now keeps its
annotation, which is the spelling it already had when no cast wrapped it:

  $ cat > b.wat <<'WAT'
  > (module
  >   (type $t (struct))
  >   (func (export "f")
  >     block (result anyref)
  >       ref.null $t
  >     end
  >     ref.cast anyref
  >     ref.null eq
  >     drop
  >     drop))
  > WAT
  $ wax -i wat -f wax b.wat
  type t = { };
  #[export]
  fn f() {
      do &?any {
          null as &?t;
      }
      _ = null as &?eq;
      _ = _;
  }
  $ wax -i wat -f wax b.wat -o b.wax && wax -i wax -f wasm b.wax -o /dev/null --validate

Dropping the cast is still right where the leftover is the block's own trailing
value: the function's result type supplies it again on a re-parse.

  $ cat > t.wat <<'WAT'
  > (module
  >   (type $t (struct))
  >   (func (export "f") (result anyref)
  >     block (result anyref)
  >       ref.null $t
  >     end
  >     ref.cast anyref))
  > WAT
  $ wax -i wat -f wax t.wat
  type t = { };
  #[export]
  fn f() -> &?any {
      do {
          null as &?t;
      }
  }
  $ wax -i wat -f wax t.wat -o t.wax && wax -i wax -f wasm t.wax -o /dev/null --validate

`if`, `loop` and `try` carry the same result annotation and reach the same
shape, so each keeps its own:

  $ cat > o.wat <<'WAT'
  > (module
  >   (type $t (struct))
  >   (tag $e)
  >   (func (export "i") (param $c i32)
  >     local.get $c
  >     if (result anyref)
  >       ref.null $t
  >     else
  >       ref.null $t
  >     end
  >     ref.cast anyref
  >     ref.null eq
  >     drop
  >     drop)
  >   (func (export "l")
  >     loop (result anyref)
  >       ref.null $t
  >     end
  >     ref.cast anyref
  >     ref.null eq
  >     drop
  >     drop)
  >   (func (export "t")
  >     try_table (result anyref) (catch_all 0)
  >       ref.null $t
  >     end
  >     ref.cast anyref
  >     ref.null eq
  >     drop
  >     drop))
  > WAT
  $ wax -i wat -f wax o.wat -o o.wax && cat o.wax
  type t = { };
  tag e();
  #[export]
  fn i(c: i32) {
      if c => &?any {
          null as &?t;
      } else {
          null as &?t;
      }
      _ = null as &?eq;
      _ = _;
  }
  #[export]
  fn l() {
      loop &?any {
          null as &?t;
      }
      _ = null as &?eq;
      _ = _;
  }
  #[export]
  fn t() 'l: {
      try &?any {
          null as &?t;
      } catch [ _ -> 'l]
      _ = null as &?eq;
      _ = _;
  }
  $ wax -i wax -f wasm o.wax -o /dev/null --validate
