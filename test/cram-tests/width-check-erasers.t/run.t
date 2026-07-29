"Width drift" is the decompiler bug class where the Wax printed for a Wasm opcode
re-infers at a different width on recompile (a numeric literal tree with nothing
to pin it re-defaults to i32/f64), silently changing the opcode and so the value
or the traps. The type checker owns the invariant: `From_wasm` RECORDS the type
each source opcode states on the node it emits, and the typer reconciles that
record with the type it resolves, PINNING any value that would otherwise default
to another width. `--debug width-check` reports each such pin instead of placing
it — the developer's view of where the decompiler is relying on the backstop.

`erasers.wat` enumerates the width erasers (the consumers whose Wax surface does
not carry their operand's width) around width-sensitive i64/f32 trees, plus the
dead-code shapes where every operand is a hole. Decompiling it is clean, which is
the user-facing assertion: every width is carried, however the pin got there.

  $ wax -i wat -f wax erasers.wat -o /dev/null

Under `--faithful`, which keeps the stream-reshaping recoveries out and turns the
simplify pass off:

  $ wax --faithful -i wat -f wax erasers.wat -o /dev/null

And on the binary path, where the type-pinning holes are synthesized without a
source location:

  $ wax -i wat -f wasm erasers.wat -o m.wasm
  $ wax -i wasm m.wasm -f wax -o /dev/null

That the widths are carried *by the backstop* is what the detector mode shows: it
turns each pin the typer would place into an error (and, being an error, stops at
the first one), naming the expression and the two types.

  $ wax --debug width-check -i wat -f wax erasers.wat -o /dev/null
  Error:
    Decompiler width invariant violated for '4096 >>u 40' recompiling it would
    infer 'i32' but the WebAssembly it came from requires 'i64'.
    ──➤  erasers.wat:13:14
  11 │   ;; comparison: yields i32 whatever the operands' width
  12 │   (func (export "cmp") (result i32)
  13 │     (i64.eq (i64.shr_u (i64.const 4096) (i64.const 40)) (i64.const 0)))
     ·              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  14 │   ;; eqz: i64 operand, i32 result
  15 │   (func (export "eqz") (result i32)
  Hint:
    This is an internal invariant of the WebAssembly-to-Wax conversion, not a
    problem with the input; without '--debug width-check' the conversion repairs
    it by pinning the expression.
  [128]

One class the reconciliation owns has no inferred width to disagree with at all:
a value the typer leaves UNRESOLVED (a hole on the polymorphic dead-code stack)
whose printed form nothing ascribes. The lowering reads such an operand at its
positional default — i32 wherever an operand's type picks the opcode, which is a
narrow store or atomic RMW, whose method name carries only the access width — so
an i64 record there would silently narrow the store. The pin is what states it:

  $ cat > ns.wat <<'WAT'
  > (module (memory 1) (func (export "f") unreachable i64.store16))
  > WAT
  $ wax -i wat -f wax ns.wat
  memory m: i32 [1];
  #[export]
  fn f() {
      unreachable;
      m.store16(_, _ as i64);
  }
  $ wax -i wat -f wax ns.wat -o ns.wax && wax -i wax -f wasm ns.wax -o ns.wasm
  $ wax -i wasm ns.wasm -f wat | grep -oE 'i(32|64)\.store16'
  i64.store16

The detector mode names that case in its own terms:

  $ wax --debug width-check -i wat -f wax ns.wat -o /dev/null
  Error:
    Decompiler width invariant violated for '_' recompiling it would leave its
    type unresolved but the WebAssembly it came from requires 'i64'.
  Hint:
    This is an internal invariant of the WebAssembly-to-Wax conversion, not a
    problem with the input; without '--debug width-check' the conversion repairs
    it by pinning the expression.
  [128]

Reconciliation is a decompiler self-check: a module that carries no recorded
expectation (anything but `From_wasm` output) has nothing to reconcile, so both
modes are a no-op on a wax input.

  $ wax -i wat -f wax erasers.wat -o erasers.wax
  $ wax --debug width-check -i wax erasers.wax -f wax -o /dev/null

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
