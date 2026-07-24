The `--faithful` flag turns off the decompilation normalisations that do not
re-lower to the exact original instruction stream, so a decompiled module
recompiles opcode-for-opcode. Each gate below shows the default (normalised)
decompilation and the faithful one.

`t.eq` followed by `i32.eqz` fuses to `a != b` by default (one `t.ne` on
recompile); faithful keeps `!(a == b)`, which re-lowers to the `eq; eqz` pair.

  $ cat > eqz.wat <<'WAT'
  > (module (func (export "f") (param i32 i32) (result i32)
  >   local.get 0 local.get 1 i32.eq i32.eqz))
  > WAT
  $ wax -i wat -f wax eqz.wat
  #[export]
  fn f(x: i32, x_2: i32) -> i32 {
      x != x_2;
  }
  $ wax -i wat -f wax --faithful eqz.wat
  #[export]
  fn f(x: i32, x_2: i32) -> i32 {
      !(x == x_2);
  }

A redundant (upcast) `ref.cast` decompiles to an `as` ascription the simplify
pass drops (the operand already has the target type); faithful keeps it, and it
re-emits `ref.cast`.

  $ cat > upcast.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (func (export "f") (param (ref $s)) (result anyref)
  >     local.get 0 ref.cast (ref any)))
  > WAT
  $ wax -i wat -f wax upcast.wat
  type s = { f: i32 };
  #[export]
  fn f(x: &s) -> &?any {
      x;
  }
  $ wax -i wat -f wax --faithful upcast.wat
  type s = { f: i32 };
  #[export]
  fn f(x: &s) -> &?any {
      x as &any;
  }

A flat `br_on_cast_fail` chain (one discarded block per arm) is recovered as a
`match` by default, which re-lowers to the nested `br_on_cast` ladder rather
than the original flat chain; faithful keeps the flat blocks.

  $ cat > flat.wat <<'WAT'
  > (module
  >   (type $a (struct (field i32)))
  >   (type $b (struct (field i64)))
  >   (func (export "f") (param anyref) (result i32)
  >     (block $L0 (result anyref)
  >       local.get 0
  >       br_on_cast_fail $L0 anyref (ref $a)
  >       drop
  >       i32.const 1
  >       return)
  >     drop
  >     (block $L1 (result anyref)
  >       local.get 0
  >       br_on_cast_fail $L1 anyref (ref $b)
  >       drop
  >       i32.const 2
  >       return)
  >     drop
  >     i32.const 0))
  > WAT
  $ wax -i wat -f wax flat.wat
  type a = { f: i32 };
  type b = { f: i64 };
  #[export]
  fn f(x: &?any) -> i32 {
      match x {
          &a => {
              return 1;
          }
          &b => {
              return 2;
          }
          _ => {
              0;
          }
      }
  }
  $ wax -i wat -f wax --faithful flat.wat
  type a = { f: i32 };
  type b = { f: i64 };
  #[export]
  fn f(x: &?any) -> i32 {
      _ =
          'L0: do &?any {
              _ = br_on_cast_fail 'L0 &a x;
              return 1;
          };
      _ =
          'L1: do &?any {
              _ = br_on_cast_fail 'L1 &b x;
              return 2;
          };
      0;
  }

A narrow load immediately widened to `i64` (`i32.load8_s; i64.extend_i32_s`)
decompiles to a single-cast `m.load8(x) as i64_s` by default; faithful keeps the
two-cast spelling `as i32_s as i64_s`. This fusion lives in the recompiler
peephole shared with hand-written Wax, not in the decompiler, so both forms
still recompile to the single fused `i64.load8_s` — the one round-trip
divergence `--faithful` cannot remove.

  $ cat > widen.wat <<'WAT'
  > (module (memory 1) (func (export "f") (param i32) (result i64)
  >   local.get 0 i32.load8_s i64.extend_i32_s))
  > WAT
  $ wax -i wat -f wax widen.wat
  memory m: i32 [1];
  #[export]
  fn f(x: i32) -> i64 {
      m.load8(x) as i64_s;
  }
  $ wax -i wat -f wax --faithful widen.wat
  memory m: i32 [1];
  #[export]
  fn f(x: i32) -> i64 {
      m.load8(x) as i32_s as i64_s;
  }

`--faithful` applies only to decompilation (wax output); it is a usage error
otherwise.

  $ NO_COLOR=1 wax -i wat -f wat --faithful eqz.wat
  --faithful is only supported for wax output
  [123]
