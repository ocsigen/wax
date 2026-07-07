A memory or table name is a static immediate, not a stack operand, so when it
appears as a method/index receiver or as a cross-mem/table `copy` source it must
not count as a value occurring *before* a hole `_`. Here `memory.copy $a $b`
decompiles to `a.copy(b, _, s, n)`: the source memory `b` is a name (immediate),
and the destination `_` is the hole taken from the enclosing stack — `b` must
not be reported as "occurring before a hole".

  $ cat > copy.wat <<'WAT'
  > (module
  >   (memory $a 1)
  >   (memory $b 1)
  >   (func (export "f") (param $s i32) (param $n i32)
  >     i32.const 0
  >     (block (param i32)
  >       local.get $s
  >       local.get $n
  >       memory.copy $a $b)))
  > WAT

  $ wax -i wat -f wax copy.wat
  memory a: i32 [1];
  memory b: i32 [1];
  #[export]
  fn f(s: i32, n: i32) {
      0;
      do (i32) {
          a.copy(b, _, s, n);
      }
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax copy.wat -o copy.wax && wax -i wax -f wasm copy.wax -o /dev/null --validate

A data/element segment operand is also a static immediate. `memory.init $m $d`
decompiles to `m.init(d, _, s, n)`: the segment `d` is a name, the destination
`_` is the hole, and `d` must not be reported as occurring before it:

  $ cat > init.wat <<'WAT'
  > (module
  >   (memory $m 1)
  >   (data $d "ab")
  >   (func (export "f") (param $s i32) (param $n i32)
  >     i32.const 0
  >     (block (param i32)
  >       local.get $s
  >       local.get $n
  >       memory.init $m $d)))
  > WAT

  $ wax -i wat -f wax init.wat
  memory m: i32 [1];
  data d = "ab";
  #[export]
  fn f(s: i32, n: i32) {
      0;
      do (i32) {
          m.init(d, _, s, n);
      }
  }

  $ wax -i wat -f wax init.wat -o init.wax && wax -i wax -f wasm init.wax -o /dev/null --validate
