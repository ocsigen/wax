The (@if) x dead-code corner (ATIF-DEADCODE.md, backing-scan grid ScondEq/
ScondNe cells). A conditional annotation is validated by SPLICING each branch
into the enclosing frame (per configuration), so a branch can consume an
enclosing dead residual — which lets a residual of the WRONG hierarchy (or a
numeric) sit where a dead reference op's hole would reconnect to it, a shape
plain wasm can never build (its validator types the residual into the consumer
and rejects). The tree the lowering reads instead types each branch as an
isolated void block: `From_wasm`'s backing scan models THAT rule (an annotation
claims nothing), and a backing the reader's pin could not ascribe gets the
CLAIM-FREE type ascription (`(_ : &?none)` and kin), which the typer gives no
pending value — ascription asserts, it does not operate, so it grounds the
hole without capturing the residual a branch consumes, and lowers to nothing.

A funcref residual under the annotation backs the `ref.is_null` hole bare (any
reference recovers `ref.is_null`); the extern residual deeper is what the
spliced else-configuration's `!_` reads. This used to crash the decompile
(typing.ml's expected-side assertion, via the `&?any` pin capturing the
funcref):

  $ cat > isnull.wat <<'WAT'
  > (module (elem declare func $f) (func $f (result i64) (i64.const 1))
  >   (func
  >     return
  >     extern.convert_any
  >     ref.func $f
  >     (@if $dbg (@then drop) (@else drop))
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax isnull.wat -o isnull.wax && cat isnull.wax
  fn f() -> i64 {
      1;
  }
  fn f_2() {
      return;
      _ as &any as &extern;
      f;
      #[if(dbg)]
      {
          _ = _;
      }
      #[else]
      {
          _ = _;
      }
      _ = !_;
      unreachable;
  }
  $ wax isnull.wax -f wat
  (func $f (result i64) (i64.const 1))
  (func $f_2
    (return)
    (extern.convert_any)
    (ref.func $f)
    (@if $dbg (@then (drop)) (@else (drop)))
    (drop (ref.is_null))
    (unreachable)
  )
  (elem declare func $f)

An extern residual the branches consume, under `ref.eq`: extern is no
`eq`-subtype, so a bare `_ == _` capturing it would not type-check and an
`(_ as &?eq)` pin capturing it would cross hierarchies. Both holes take the
claim-free ascription, which lowers to nothing:

  $ cat > refeq.wat <<'WAT'
  > (module
  >   (func
  >     return
  >     extern.convert_any
  >     (@if $dbg (@then drop) (@else drop))
  >     ref.eq
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax refeq.wat -o refeq.wax && cat refeq.wax
  fn f() {
      return;
      _ as &any as &extern;
      #[if(dbg)]
      {
          _ = _;
      }
      #[else]
      {
          _ = _;
      }
      _ = (_ : &?none) == (_ : &?none);
      unreachable;
  }
  $ wax refeq.wax -f wat
  (func $f
    (return)
    (extern.convert_any)
    (@if $dbg (@then (drop)) (@else (drop)))
    (drop (ref.eq))
    (unreachable)
  )

A width-tagged NUMERIC residual the branches consume, under `ref.is_null`: the
positional capture would be the `i64.add` value (claiming is type-blind), which
neither a bare `!_` (re-defaults to `i32.eqz`) nor the `&?any` pin (fails to
type) survives — the scan's `` `Value`` verdict routes it to the bottom pin
too. This used to crash the wax->wat direction (`to_wasm`'s cast lowering, on
the poisoned i64-to-reference cast):

  $ cat > num.wat <<'WAT'
  > (module
  >   (func
  >     return
  >     i64.add
  >     (@if $dbg (@then drop) (@else drop))
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax num.wat -o num.wax && cat num.wax
  fn f() {
      return;
      (_ + _) as i64;
      #[if(dbg)]
      {
          _ = _;
      }
      #[else]
      {
          _ = _;
      }
      _ = !(_ : &?none);
      unreachable;
  }
  $ wax num.wax -f wat
  (func $f
    (return)
    (i64.add)
    (@if $dbg (@then (drop)) (@else (drop)))
    (drop (ref.is_null))
    (unreachable)
  )

The cross-hierarchy converts aim their wrong-hierarchy pin at the SOURCE
hierarchy's bottom, so the convert lowers over it exactly as the source did —
a top-of-hierarchy pin would capture the extern residual and lower to the very
`any.convert_extern` it should not add:

  $ cat > cvt.wat <<'WAT'
  > (module
  >   (func
  >     return
  >     ref.func $f
  >     (@if $dbg (@then drop) (@else drop))
  >     any.convert_extern
  >     drop
  >     unreachable)
  >   (elem declare func $f) (func $f))
  > WAT
  $ wax -i wat -f wax cvt.wat -o cvt.wax && cat cvt.wax
  fn f() {
      return;
      f_2;
      #[if(dbg)]
      {
          _ = _;
      }
      #[else]
      {
          _ = _;
      }
      _ = (_ : &extern) as &any;
      unreachable;
  }
  fn f_2() {}
  $ wax cvt.wax -f wat
  (func $f
    (return)
    (ref.func $f_2)
    (@if $dbg (@then (drop)) (@else (drop)))
    (drop (any.convert_extern))
    (unreachable)
  )
  (func $f_2)
  (elem declare func $f_2)

A member-access RECEIVER pin capturing across the annotation (the grid's
`Vmulti.ScondEq.S2` cells): the struct.set receiver hole's positional capture
is the call residual's FIRST result (its sibling value hole eats the second),
a non-reference the `&?s` pin cannot absorb — and the lowering reads the
struct type off the receiver, so the poisoned capture crashed it. The
claim-free ascription of the receiver type grounds the hole and still names
the type:

  $ cat > recv.wat <<'WAT'
  > (module
  >   (type $s (struct (field (mut i64))))
  >   (func $f2 (result i64 i64) (i64.const 1) (i64.const 2))
  >   (func
  >     return
  >     call $f2
  >     (@if $dbg (@then drop) (@else drop))
  >     struct.set $s 0
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax recv.wat -o recv.wax && grep -A1 'if(dbg)' -m1 recv.wax >/dev/null && sed -n '/}$/,$p' recv.wax | grep -E 'as &|: &|!'
      (_ : &?s).f = _;
      _ = !(_ : &?none);
  $ wax recv.wax -f wat | grep -cE 'struct.set \$s|ref.is_null|ref.cast'
  2

A width-tagged numeric residual whose positional capture belongs to an
interposed `if` CONDITION hole (`Rnum.ScondEq.Bif`): the condition claims the
`i64.add` value in the tree the lowering reads, and the reconciliation's
repair then re-grounds that shared cell at i64. This used to rewrite one of
the typer's SHARED base-type cells (the flexible operand had been union-merged
into the expected `i32` cell by `subtype`), retyping every `!` result in the
module and failing the decompile; `subtype` now settles a flexible value by
setting its own cell:

  $ cat > numif.wat <<'WAT'
  > (module
  >   (func
  >     return
  >     i64.add
  >     (@if $dbg (@then drop) (@else drop))
  >     if end
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax numif.wat -o numif.wax && wax numif.wax -f wat
  (func $f
    (return)
    (i64.add)
    (@if $dbg (@then (drop)) (@else (drop)))
    (if (then))
    (drop (ref.is_null))
    (unreachable)
  )

A branch that PUSHES a value: the spliced configurations hand it to whatever
consumer follows the annotation, so only its own printed form carries its
width — the branch body's leftovers are NOT context-typed block results
(`Stack.run ~results:0`). Unpinned, the `i64.const 1` re-lowered at the i32
default and the lowered module failed its own validation in the configuration
that feeds it to the i64 local:

  $ cat > push.wat <<'WAT'
  > (module
  >   (func (local $l64 i64)
  >     return
  >     (@if $dbg (@then i64.const 1) (@else i64.const 1))
  >     local.set $l64
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax push.wat -o push.wax && sed -n '4,10p' push.wax
      {
          1 as i64;
      }
      #[else]
      {
          1 as i64;
      }
  $ wax push.wax -f wat
  (func $f
    (local $l64 i64)
    (return)
    (@if $dbg (@then (i64.const 1)) (@else (i64.const 1)))
    (local.set $l64)
    (drop (ref.is_null))
    (unreachable)
  )

A dead `ref.cast` whose hole would capture a residual OUTSIDE its target's
hierarchy (an extern under a cast to an any-hierarchy type): bare, typing the
capture compounds the cast with an `any.convert_extern` the source never had.
The claim-free ascription grounds it — and over the ascribed bottom the cast
itself survives the round trip (one `ref.cast`, the source's own count; the
old bottom-CAST spelling could only lower the whole chain to nothing):

  $ cat > deadcast.wat <<'WAT'
  > (module
  >   (type $s (struct (field (mut i64))))
  >   (func
  >     return
  >     extern.convert_any
  >     (@if $dbg (@then drop) (@else drop))
  >     ref.cast (ref null $s)
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax deadcast.wat -o deadcast.wax && grep 'as' deadcast.wax
      _ as &any as &extern;
      _ = (_ : &?none) as &?s;
  $ wax deadcast.wax -f wat | grep -cE 'ref.cast|any.convert_extern'
  1

A pushing branch also makes every CLAIMING pin unsafe on a `Floor`/`Blocked`
verdict: the interposed `drop`'s claim is satisfied by the branch's push in
the spliced configurations, so the funcref the scan counted as absorbed is
exactly what a claiming `(_ as &?any)` would capture there (a hierarchy
crossing). With an annotation anywhere in the stack the reader pins go
claim-free:

  $ cat > pushfn.wat <<'WAT'
  > (module
  >   (elem declare func $f) (func $f)
  >   (func
  >     return
  >     ref.func $f
  >     (@if $dbg (@then i64.const 1) (@else i64.const 1))
  >     drop
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax pushfn.wat -o pushfn.wax && grep '!' pushfn.wax
      _ = !(_ : &?none);
  $ wax pushfn.wax -f wat | grep -c 'ref.is_null'
  1

And a parameterized block behind the annotation: marking the value below it
consumed would let the block's re-parse claim re-type it (here grounding the
untyped `select` at `&?extern`, so the lowered module failed its own
validation). `Stack.consume` injects a synthetic, already-consumed claim-free
bottom value for the claim instead — printed between the annotation and the
block, so a dropping branch still eats the value below and the parameter's
claim lands on the synthetic in every configuration — and the `select` stays
untyped:

  $ cat > pushblk.wat <<'WAT'
  > (module
  >   (func
  >     return
  >     select
  >     (@if $dbg (@then ref.null extern) (@else ref.null extern))
  >     block (param externref) drop end
  >     ref.eq
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax pushblk.wat -o pushblk.wax && sed -n '3p;12,15p' pushblk.wax
      _?_:_;
      (_ : &?noextern);
      do (&?extern) {
          _ = _;
      }
  $ wax pushblk.wax -f wat | grep -cE '\(select\)|ref.eq'
  2

With NOTHING below the annotation, the synthetic is not injected at all:
every pass already agrees (the parameter draws from the polymorphic floor in
the lowered tree, and from the branch's own push in the spliced
configurations — the source's exact pairing), and a synthetic would only
strand the push onto the numeric sink:

  $ cat > pushsink.wat <<'WAT'
  > (module
  >   (func (local $l64 i64)
  >     return
  >     (@if $dbg (@then ref.null extern) (@else ref.null extern))
  >     block (param externref) drop end
  >     local.set $l64
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax pushsink.wat -o pushsink.wax && grep -cE 'noextern' pushsink.wax
  0
  [1]
  $ wax pushsink.wax -f wat
  (func $f
    (local $l64 i64)
    (return)
    (@if $dbg (@then (ref.null extern)) (@else (ref.null extern)))
    (block (param externref) (drop))
    (local.set $l64)
    (drop (ref.is_null))
    (unreachable)
  )

Depth-4 shapes (the nightly lane's depth) — a numeric operator right after the
annotation, its operand holes reaching a REFERENCE residual below: the record
alone cannot keep the width (the mis-typed tree resolves the cell as the
reference and the width machinery skips it), so the holes get the syntactic
pin, whose printed target survives the re-parse and keeps `i64.add` an
`i64.add`:

  $ cat > numref.wat <<'WAT'
  > (module
  >   (func (local $l64 i64)
  >     return
  >     extern.convert_any
  >     (@if $dbg (@then drop) (@else drop))
  >     i64.add
  >     local.set $l64
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax numref.wat -o numref.wax && grep 'as i64' numref.wax
      let l64: i64 = _ as i64 + _ as i64;
  $ wax numref.wax -f wat | grep -cE 'i64.add|ref.is_null'
  2

And a consumed adaptive select: the select's own arm holes claim BEFORE the
parameterized block's claim (the consumed entry prints as its own statement),
so the scan charges them — unaccounted, the extern below looked like the
reader's backing and the bare `!_` re-defaulted to `i32.eqz`:

  $ cat > selpar.wat <<'WAT'
  > (module
  >   (func
  >     return
  >     extern.convert_any
  >     (@if $dbg (@then drop) (@else drop))
  >     select
  >     block (param externref) drop end
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax selpar.wat -o selpar.wax && grep '!' selpar.wax
      _ = !(_ : &?none);
  $ wax selpar.wax -f wat | grep -cE 'ref.is_null'
  1

A hole-initialized binding keeps its annotation in a conditional module: the
hole's claim differs per configuration (here the branch owns the i64 in the
spliced world), so the annotation the lowered tree finds redundant is the only
thing that types the binding in the other configuration:

  $ cat > holelet.wat <<'WAT'
  > (module
  >   (func $f3 (result i64 externref) (i64.const 1) (ref.null extern))
  >   (func (local $l64 i64)
  >     return
  >     call $f3
  >     drop
  >     (@if $dbg (@then drop) (@else drop))
  >     local.set $l64
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax holelet.wat -o holelet.wax && grep 'let l64' holelet.wax
      let l64: i64 = _;
  $ wax holelet.wax -f wat | grep -cE 'local.set|ref.is_null'
  2
