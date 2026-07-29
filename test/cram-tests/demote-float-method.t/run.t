`f32.demote_f64` is a width eraser: its Wax surface is a plain `as f32`, so a
width-flexible f64 operand (a float method whose width follows a bare literal, or
a value stranded past a statement that a trailing hole reconnects to) re-defaults
toward f32 and the demote collapses into an `f32.sqrt`/`f32.trunc` — a precision
change, not just an opcode shuffle. `From_wasm` renders the demote as the double
cast `(operand as f64) as f32`, and on the default (simplify) path the Wax typer
keeps the inner `as f64` rather than dropping it as redundant (f64 is the float
re-parse default), so the demote survives. That holds for a bare f64 CONSTANT too:
the typer's own redundancy rule treats its demote as value-inert (`f64.const` then
demote equals the `f32.const`) and drops the inner cast, but the width
reconciliation puts it back from the width `From_wasm` recorded on the literal —
so the whole opcode stream, `f64.const` and demote included, round-trips exactly
rather than folding to an `f32.const`. (Value-inert is not always exact: a decimal
literal rounded once to f64 and then demoted can differ from the same decimal
rounded straight to f32.)

  $ cat > m.wat <<'WAT'
  > (module
  >   (func $demote_sqrt (result f32) f64.const 0x1p+1 f64.sqrt f32.demote_f64)
  >   (func $demote_trunc (result f32) f64.const 0x1.5p+1 f64.trunc f32.demote_f64)
  >   (func $demote_lit (result f32) f64.const 0x1.5p+1 f32.demote_f64)
  >   (func $block_strand (result f32)
  >     (block (result f32) f64.const 0x1.5p+1 f64.trunc (block) f32.demote_f64)))
  > WAT
  $ wax -i wat -f wax m.wat
  fn demote_sqrt() -> f32 {
      (0x1p+1).sqrt() as f64 as f32;
  }
  fn demote_trunc() -> f32 {
      (0x1.5p+1).trunc() as f64 as f32;
  }
  fn demote_lit() -> f32 {
      0x1.5p+1 as f64 as f32;
  }
  fn block_strand() -> f32 {
      do {
          (0x1.5p+1).trunc();
          do {}
          _ as f64 as f32;
      }
  }

Round-tripping keeps the f64 method (and demote) rather than narrowing it to an
f32 method, and keeps the literal's demote as well — the stream below is exactly
the input's:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o m.wasm
  $ wax -i wasm -f wat m.wasm | grep -oE 'f(32|64)\.(sqrt|trunc|demote_f64|const)'
  f64.const
  f64.sqrt
  f32.demote_f64
  f64.const
  f64.trunc
  f32.demote_f64
  f64.const
  f32.demote_f64
  f64.const
  f64.trunc
  f32.demote_f64
