Regression (wasm-smith fuzzer, reduced): an EXTERN-hierarchy source pin may only
capture nothing.

`ref.cast` into the extern hierarchy, and `any.convert_extern`, share the Wax
`as &extern` surface with the cross-hierarchy convert, so `from_wasm` pins a
dead-code hole `(_ as &?extern)` to keep the opcode family. Unlike every other
top-of-hierarchy pin that one CROSSES hierarchies, so it is not inert over
whatever it lands on: over a value that re-parses in the any hierarchy it *is*
`extern.convert_any`, the opcode it exists to prevent. Three shapes put
something under it; each round-trips to its own single opcode now.

A forwarding `br_on_null` consumed directly by the cast: the pin belongs on the
tested ref inside the branch, not around the branch's (any-defaulted) result.

  $ cat > a.wat <<'WAT'
  > (module
  >   (func (export "f")
  >     block
  >       br 0
  >       br_on_null 0
  >       ref.cast (ref extern)
  >       drop
  >     end))
  > WAT
  $ wax -i wat -f wax --faithful a.wat
  #[export]
  fn f() {
      'l: do {
          br 'l;
          _ = (br_on_null 'l _ as &?extern) as &extern;
      }
  }
  $ wax -i wat -f wax --faithful a.wat -o a.wax && wax -i wax -f wat a.wax | grep -oE 'br_on_null|ref\.cast|extern\.convert_any'
  ref.cast
  br_on_null

Split from the cast by a statement, the hole reconnects to that `br_on_null`
residual instead. The residual is adaptive, so it takes the extern hierarchy
from the cast's own surface and the hole stays bare — a pin here would land on
the residual and cross.

  $ cat > b.wat <<'WAT'
  > (module
  >   (func (export "f")
  >     block
  >       br 0
  >       br_on_null 0
  >       nop
  >       ref.cast (ref noextern)
  >       drop
  >     end))
  > WAT
  $ wax -i wat -f wax --faithful b.wat
  #[export]
  fn f() {
      'l: do {
          br 'l;
          br_on_null 'l _ as &?extern;
          nop;
          _ = _ as &noextern;
      }
  }
  $ wax -i wat -f wax --faithful b.wat -o b.wax && wax -i wax -f wat b.wax | grep -oE 'br_on_null|ref\.cast|extern\.convert_any'
  br_on_null
  ref.cast

A `ref.as_non_null` residual is NOT adaptive — printed as its own statement it
types independently and defaults to the any hierarchy — so neither a bare hole
nor a pin over it works: the residual itself is grounded at the source.

  $ cat > c.wat <<'WAT'
  > (module
  >   (func (export "f")
  >     block
  >       br 0
  >       ref.as_non_null
  >       nop
  >       ref.cast (ref extern)
  >       drop
  >     end))
  > WAT
  $ wax -i wat -f wax --faithful c.wat
  #[export]
  fn f() {
      'l: do {
          br 'l;
          (_ as &?extern)!;
          nop;
          _ = _ as &extern;
      }
  }
  $ wax -i wat -f wax --faithful c.wat -o c.wax && wax -i wax -f wat c.wax | grep -oE 'ref\.as_non_null|ref\.cast|extern\.convert_any'
  ref.as_non_null
  ref.cast

Both at once — the pin inside a `br_on_null` whose own hole reconnects to a
`ref.as_non_null` residual — and the `any.convert_extern` mirror, whose source
pin crosses the same way:

  $ cat > d.wat <<'WAT'
  > (module
  >   (func (export "f")
  >     block
  >       br 0
  >       ref.as_non_null
  >       nop
  >       br_on_null 0
  >       ref.cast (ref extern)
  >       drop
  >     end)
  >   (func (export "g")
  >     block
  >       br 0
  >       ref.as_non_null
  >       nop
  >       any.convert_extern
  >       drop
  >     end))
  > WAT
  $ wax -i wat -f wax --faithful d.wat -o d.wax && wax -i wax -f wat d.wax | grep -oE 'ref\.as_non_null|br_on_null|ref\.cast|any\.convert_extern|extern\.convert_any'
  ref.as_non_null
  ref.cast
  br_on_null
  ref.as_non_null
  any.convert_extern

The pin is still applied where the hole really does spring from the polymorphic
bottom with nothing to reconnect to — without it the cast is absorbed and lost:

  $ cat > e.wat <<'WAT'
  > (module
  >   (func (export "f")
  >     br 0
  >     ref.cast (ref noextern)
  >     drop))
  > WAT
  $ wax -i wat -f wax --faithful e.wat
  #[export]
  fn f() 'l: {
      br 'l;
      _ = _ as &?extern as &noextern;
  }
  $ wax -i wat -f wax --faithful e.wat -o e.wax && wax -i wax -f wat e.wax | grep -oE 'ref\.cast|extern\.convert_any'
  ref.cast


The same rule governs every other pin over a FORWARDING operand — one that
carries its reference inside a `ref.as_non_null`. Wrapping the forwarder pins
its own (bottom, non-null) result, and the surface `as` then has to cast it, so
the pin goes inside: a `call_ref` callee, a member-access receiver, an
`array.len` receiver, an `i31.get_s` source, and the `any`-side convert whose
residual is grounded like the extern-side one above. Each keeps its single
opcode:

  $ cat > f.wat <<'WAT'
  > (module
  >   (type $s (struct (field (mut i64))))
  >   (type $a (array (mut i64)))
  >   (type $ft (func (result i64 externref)))
  >   (func (export "callee")
  >     return
  >     ref.as_non_null
  >     call_ref $ft
  >     drop
  >     drop)
  >   (func (export "recv")
  >     return
  >     ref.as_non_null
  >     struct.get $s 0
  >     drop)
  >   (func (export "arr")
  >     return
  >     ref.as_non_null
  >     array.len
  >     drop)
  >   (func (export "i31")
  >     return
  >     ref.as_non_null
  >     i31.get_s
  >     drop)
  >   (func (export "cvtx")
  >     return
  >     ref.as_non_null
  >     nop
  >     extern.convert_any
  >     drop))
  > WAT
  $ wax -i wat -f wax --faithful f.wat -o f.wax && cat f.wax
  type s = { f: mut i64 };
  type a = [mut i64];
  type ft = fn() -> (i64, &?extern);
  #[export]
  fn callee() {
      return;
      ((_ as &?ft)!)();
      _ = _;
      _ = _;
  }
  #[export]
  fn recv() {
      return;
      _ = ((_ as &?s)!).f;
  }
  #[export]
  fn arr() {
      return;
      _ = ((_ as &?array)!).length();
  }
  #[export]
  fn i31() {
      return;
      _ = (_ as &?i31)! as i32_s;
  }
  #[export]
  fn cvtx() {
      return;
      (_ as &?any)!;
      nop;
      _ = _ as &?extern;
  }

Every `ref.as_non_null` is still exactly one opcode, and no `ref.cast` is
introduced anywhere:

  $ wax -i wax -f wat f.wax | grep -oE 'ref\.as_non_null' | wc -l
  5
  $ wax -i wax -f wat f.wax | grep -oE 'ref\.cast' | wc -l
  0
