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

The two reserved frequency values print as their keywords rather than as a byte:

  $ wax -i wat -f wat reserved.wat
  (func $f (param i32)
    (@metadata.code.instr_freq (never_opt))
    (loop $l (@metadata.code.instr_freq (always_opt)) (br_if $l (local.get 0)))
  )

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
    · ╭───^
  4 │     (i32.const 0)))
    · ╰───────────────^
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
    · ╭───^
  8 │     (call_indirect $t (type $ft) (i32.const 0))))
    · ╰─────────────────────────────────────────────^
  9 │ 
  [128]
