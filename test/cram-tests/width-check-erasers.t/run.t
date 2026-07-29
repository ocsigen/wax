"Width drift" is the decompiler bug class where the Wax printed for a Wasm opcode
re-infers at a different width on recompile (a numeric literal tree with nothing
to pin it re-defaults to i32/f64), silently changing the opcode and so the value
or the traps. `From_wasm` prevents it by pinning such values, and records the type
each source opcode states on the node it emits. The type checker then reconciles
its own inference with those records, and by DEFAULT it repairs a disagreement: a
value that merely defaulted to the wrong width is pinned, so a gap in the
conversion's own pins costs an extra cast instead of a silent miscompile.
`--debug width-check` turns the backstop back into a detector — it reports the
disagreement instead of repairing it, which is what lets the fuzzing harness see
a missing pin at all.

`erasers.wat` enumerates the width erasers (the consumers whose Wax surface does
not carry their operand's width) around width-sensitive i64/f32 trees, plus the
dead-code shapes where every operand is a hole. The conversion's own pins hold, so
there is nothing to repair and nothing to report:

  $ wax --debug width-check -i wat -f wax erasers.wat -o /dev/null

Under `--faithful`, which keeps the stream-reshaping recoveries out and turns the
simplify pass off:

  $ wax --debug width-check --faithful -i wat -f wax erasers.wat -o /dev/null

And on the binary path, where the type-pinning holes are synthesized without a
source location:

  $ wax -i wat -f wasm erasers.wat -o m.wasm
  $ wax --debug width-check -i wasm m.wasm -f wax -o /dev/null

Repair is therefore inert here: the decompilation is byte for byte what the
detector mode prints.

  $ wax -i wat -f wax erasers.wat -o repaired.wax
  $ wax --debug width-check -i wat -f wax erasers.wat -o reported.wax
  $ diff repaired.wax reported.wax && echo identical
  identical

Reconciliation is a decompiler self-check: a module that carries no recorded
expectation (anything but `From_wasm` output) has nothing to reconcile, so both
modes are a no-op on a wax input.

  $ wax --debug width-check -i wax repaired.wax -f wax -o /dev/null

A disagreement a pin CANNOT fix is an error in both modes, repair included: when
the value's type is fixed by its context rather than defaulted, a cast there would
convert the value instead of grounding it. A *type-incorrect* binary shows that end
to end — the conversion trusts a binary and records what each opcode states, so a
module whose operands do not match its opcodes disagrees by construction.
`bad.wasm` below is `(func (result f64) i64.const 0 f32.const 0 f64.copysign)`:
`f64.copysign` takes its receiver as f64, but an `i64.const` is what is there, and
the conversion's receiver pin fixes the node at f64, which is not the type it came
from (i64).

  $ printf '\000asm\001\000\000\000\001\005\001\140\000\001\174\003\002\001\000\012\014\001\012\000B\000C\000\000\000\000\246\013' > bad.wasm
  $ wax -i wasm bad.wasm -f wax -o /dev/null
  File "bad.wasm", line 1, characters 24-26:
  Error:
    Decompiler width invariant violated for '0' recompiling it would infer 'f64'
    but the WebAssembly it came from requires 'i64': its type is fixed by
    context, not defaulted, so no pin can correct it.
  Hint:
    Either this WebAssembly is invalid — a binary input is trusted, never
    validated, so check it with 'wax check' — or the WebAssembly-to-Wax
    conversion is wrong. A cast here would convert the value rather than pin it,
    so the conversion does not repair it.
  [128]

The detector mode says the same thing, since neither mode can repair it:

  $ wax --debug width-check -i wasm bad.wasm -f wax -o /dev/null
  File "bad.wasm", line 1, characters 24-26:
  Error:
    Decompiler width invariant violated for '0' recompiling it would infer 'f64'
    but the WebAssembly it came from requires 'i64': its type is fixed by
    context, not defaulted, so no pin can correct it.
  Hint:
    Either this WebAssembly is invalid — a binary input is trusted, never
    validated, so check it with 'wax check' — or the WebAssembly-to-Wax
    conversion is wrong. A cast here would convert the value rather than pin it,
    so the conversion does not repair it.
  [128]

Which is the reconciliation's one caveat: the recorded widths are claims about a
module the decompiler was handed, so they only mean anything when that module is
valid — `wax check` rejects this one.

  $ wax check -f wasm bad.wasm > /dev/null
  File "bad.wasm", line 1, characters 26-31:
  Error:
    Type mismatch: this produces a value of type 'f32', but type 'f64' is
    expected.
  File "bad.wasm", line 1, characters 24-26:
  Error:
    Type mismatch: this produces a value of type 'i64', but type 'f64' is
    expected.
  [128]
