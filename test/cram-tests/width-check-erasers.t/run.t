"Width drift" is the decompiler bug class where the Wax printed for a Wasm opcode
re-infers at a different width on recompile (a numeric literal tree with nothing
to pin it re-defaults to i32/f64), silently changing the opcode and so the value
or the traps. `From_wasm` prevents it by pinning such values, and records the type
each source opcode states on the node it emits; `--debug width-check` makes the
type checker compare its own inference against those records, so a drift is
reported instead of printed.

`erasers.wat` enumerates the width erasers (the consumers whose Wax surface does
not carry their operand's width) around width-sensitive i64/f32 trees, plus the
dead-code shapes where every operand is a hole. The pins hold, so the check is
silent:

  $ wax --debug width-check -i wat -f wax erasers.wat -o /dev/null

Under `--faithful`, which keeps the stream-reshaping recoveries out and turns the
simplify pass off:

  $ wax --debug width-check --faithful -i wat -f wax erasers.wat -o /dev/null

And on the binary path, where the type-pinning holes are synthesized without a
source location:

  $ wax -i wat -f wasm erasers.wat -o m.wasm
  $ wax --debug width-check -i wasm m.wasm -f wax -o /dev/null

The check is a decompiler self-check: a module that carries no recorded
expectation (anything but `From_wasm` output) reports nothing, so asking for it on
a wax input is a no-op.

  $ wax --debug width-check -i wat -f wax erasers.wat -o erasers.wax
  $ wax --debug width-check -i wax erasers.wax -f wax -o /dev/null

The check is not vacuous: it fires whenever a node's recorded type and the
inferred one disagree, and the disagreement is an error (exit 128), so a drift
stops the conversion instead of being printed. A *type-incorrect* binary shows
that end to end — the conversion trusts a binary and records what each opcode
states, so a module whose operands do not match its opcodes disagrees by
construction. `bad.wasm` below is `(func (result f64) i64.const 0 f32.const 0
f64.copysign)`: `f64.copysign` takes its receiver as f64, but an `i64.const` is
what is there, and the conversion's receiver pin casts it, so the type the node
is given (f64) is not the one it came from (i64).

  $ printf '\000asm\001\000\000\000\001\005\001\140\000\001\174\003\002\001\000\012\014\001\012\000B\000C\000\000\000\000\246\013' > bad.wasm
  $ wax --debug width-check -i wasm bad.wasm -f wax -o /dev/null
  File "bad.wasm", line 1, characters 24-26:
  Error:
    Decompiler width invariant violated for '0' recompiling it would infer 'f64'
    but the WebAssembly it came from requires 'i64'.
  Hint:
    This is an internal invariant of the WebAssembly-to-Wax conversion, not a
    problem with the input.
  [128]

Which is also the check's one caveat: it is only meaningful on a module the
validator accepts. Without `--debug width-check` the same conversion is silent, so
nothing about the normal pipeline changes.

  $ wax -i wasm bad.wasm -f wax
  type t = fn() -> f64;
  fn f() -> f64 {
      (0).copysign(0x0p+0);
  }
