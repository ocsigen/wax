Regression (backing-scan grid, `Rnn.ScondPush*` cells): with a conditional
annotation in the stack, a type pin over an UNCLASSIFIABLE residual must be the
claim-free ascription `(_ : t)`, not the claiming cast `(_ as t)`.

The two spellings differ in what they lower to. An ascription compiles to no
instruction, so it states a type without taking a value; a cast compiles to a
`ref.cast`, which claims the pending value sitting on the stack at that point.
Behind an `(@if)` the pending is a branch's push, not the residual the hole was
meant for — so the claiming pin takes the wrong value.

A member access whose receiver's backing is a `ref.as_non_null` residual. The
receiver claims before the value operand's hole does, so a claiming pin makes
the access unspellable and the decompiler's own output was rejected ("This
expression occurs before a hole `_`"):

  $ cat > a.wat <<'WAT'
  > (module
  >   (type $s (struct (field (mut i64))))
  >   (func (export "f")
  >     return
  >     ref.as_non_null
  >     (@if $dbg (@then i64.const 1) (@else i64.const 1))
  >     struct.set $s 0
  >     ref.is_null
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax --faithful a.wat
  type s = { f: mut i64 };
  #[export]
  fn f() {
      return;
      _!;
      #[if(dbg)]
      {
          1;
      }
      #[else]
      {
          1;
      }
      (_ : &?s).f = _;
      _ = !(_ : &?none);
      unreachable;
  }

A `ref.cast` into the extern hierarchy over the same kind of residual. Its
source pin and the claim-free grounding target the same hole, and the grounding
wins: applied first, the pin also replaced the hole the grounding matches on, so
for an extern target the grounding could never fire at all and the pin captured
a value a branch released — re-lowering as an `extern.convert_any` the source
never had.

  $ cat > b.wat <<'WAT'
  > (module
  >   (func (export "f")
  >     return
  >     ref.as_non_null
  >     (@if $dbg (@then ref.null extern) (@else ref.null extern))
  >     block (param externref)
  >     drop
  >     end
  >     ref.cast (ref extern)
  >     drop
  >     unreachable))
  > WAT
  $ wax -i wat -f wax --faithful b.wat -o b.wax && cat b.wax
  #[export]
  fn f() {
      return;
      _!;
      #[if(dbg)]
      {
          null as &?extern;
      }
      #[else]
      {
          null as &?extern;
      }
      do (&?extern) {
          _ = _;
      }
      _ = (_ : &?noextern) as &extern;
      unreachable;
  }
  $ wax -i wax -f wat b.wax | grep -oE 'extern\.convert_any' | wc -l | tr -d ' '
  0
