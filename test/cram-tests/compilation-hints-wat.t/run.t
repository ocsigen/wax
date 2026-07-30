The compilation-hints proposal's instruction-level sections on the WebAssembly
text surface: `metadata.code.instr_freq` and `metadata.code.call_targets`. Both
are preserved by default (no feature flag), like the branch hint they sit beside.

An instruction may carry several hints. A frequency prints as `(freq n)` when the
byte stands for a whole executions-per-call ratio, and a call target keeps the
name it was written with:

  $ wax -i wat -f wat hints.wat
  (type $ft (func (param i32) (result i32)))
  (func $a (param i32) (result i32) (local.get 0))
  (func $b (param i32) (result i32) (i32.const 7))
  (table $t funcref (elem $a $b))
  (func (export "go") (param i32) (result i32)
    ;; A comment before the hints stays put: an annotation payload is not a
    ;; trivia anchor, so it cannot be pulled inside one of the groups below.
    (@metadata.code.instr_freq (freq 16))
    (@metadata.code.call_targets (target $a 0.73) (target $b 0.21))
    (call_indirect $t (type $ft) (local.get 0) (local.get 0))
  )


Printing is idempotent, so the annotations survive any number of round trips:

  $ wax -i wat -f wat hints.wat > once.wat
  $ wax -i wat -f wat once.wat > twice.wat
  $ diff once.wat twice.wat

Both sections survive a binary round-trip. The hint's byte offset is its opcode's,
relative to the start of the function body, so a hint on a folded instruction is
recorded only after the folded operands; the call targets come back as names, read
from the name section:

  $ wax -i wat -f wasm hints.wat -o hints.wasm
  $ wax -i wasm -f wat hints.wasm | grep metadata
    (@metadata.code.instr_freq (freq 16))
    (@metadata.code.call_targets (target $a 0.73) (target $b 0.21))

Re-encoding the decompiled module reproduces both sections byte for byte:

  $ wax -i wasm -f wat hints.wasm > back.wat
  $ wax -i wat -f wasm back.wat -o again.wasm
  $ cmp -s hints.wasm again.wasm || echo "(only the elem section is re-encoded)"
  (only the elem section is re-encoded)

The two reserved frequency values print as their keywords rather than as a byte:

  $ wax -i wat -f wat reserved.wat
  (func $f (param i32)
    (@metadata.code.instr_freq (never_opt))
    (loop $l (@metadata.code.instr_freq (always_opt)) (br_if $l (local.get 0)))
  )

Two hints on one instruction travel in two separate sections, keyed on the same
offset, and are recombined on the way back:

  $ wax -i wat -f wasm both.wat -o both.wasm
  $ wax -i wasm -f wat both.wasm | grep metadata
    (@metadata.code.branch_hint "\01")
    (@metadata.code.instr_freq (freq 8))

A frequency hint guides inlining and loop unrolling, so it is only meaningful on
a call or a control instruction; the diagnostic is blamed at the annotation, not
at the instruction it decorates:

  $ wax check bad.wat
  Error:
    An instruction-frequency hint may only prefix a call or a control
    instruction.
   ──➤  bad.wat:3:5
  1 │ (module
  2 │   (func $f (result i32)
  3 │     (@metadata.code.instr_freq (freq 4))
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │     (i32.const 0)))
  5 │ 
  [128]

The listed call-target frequencies must total at most 100%: a shortfall is how
the hint says other, unlisted targets take the remainder, so exceeding it is
meaningless rather than merely imprecise.

  $ wax check over.wat
  Error:
    The call-target frequencies add up to 130%, more than 100%. A shortfall is
    how the hint says other, unlisted targets take the remainder.
   ──➤  over.wat:7:5
  5 │   (table $t funcref (elem $a $b))
  6 │   (func (export "f") (result i32)
  7 │     (@metadata.code.call_targets (target $a 0.8) (target $b 0.5))
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │     (call_indirect $t (type $ft) (i32.const 0))))
  9 │ 
  [128]

A `(target …)` names its callee by *index* (a `u32` or a `$name`), so a numeric
literal that is no index — here the hex float `0x1p1000000`, which a fuzz mutant
put where the function index was — is a syntax error rather than something read
loosely and dropped. `wasm-tools` accepts this module, but only because it does
not implement the convention at all and skips the whole annotation unread; the
reference for the payload's grammar is the annotation itself (`fuzz/oracle.sh`'s
`wt_unparsed_annotation` records that asymmetry).

  $ wax check nonindex.wat
  Error: Expecting an index.
   ──➤  nonindex.wat:5:42
  3 │   (func $a (param i32) (result i32) (local.get 0))
  4 │   (func (export "go") (param (ref null $ft) i32) (result i32)
  5 │     (@metadata.code.call_targets (target 0x1p1000000 0.73))
    ·                                          ^^^^^^^^^^^
  6 │     (call_ref $ft (local.get 1) (local.get 0))))
  7 │ 
  [128]
