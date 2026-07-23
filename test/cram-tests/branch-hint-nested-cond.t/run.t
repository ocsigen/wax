A `#[likely]` `if` used as the *condition* of another `#[likely]` `if` produces
two branch hints, each on its own `if`. wax prints them folded, with each
`@metadata.code.branch_hint` before its `(if` group — the same placement binaryen
emits — and encodes each hint at its branch opcode's offset, so the two land on
distinct offsets.

  $ wax -f wat m.wax
  (func $f (param $x i32) (result i32)
    (@metadata.code.branch_hint "\01")
    (if (result i32)
      (@metadata.code.branch_hint "\01")
      (if (result i32) (local.get $x) (then (i32.const 1)) (else (i32.const 2)))
      (then (i32.const 1))
      (else (i32.const 2)))
  )

wax parses that folded operand placement back (it used to accept the annotation
only at statement position, not before a folded operand), so its own output — and
binaryen's, which is byte-identical — round-trips:

  $ wax -f wat m.wax | wax -i wat -f wat
  (func $f (param $x i32) (result i32)
    (@metadata.code.branch_hint "\01")
    (if (result i32)
      (@metadata.code.branch_hint "\01")
      (if (result i32) (local.get $x) (then (i32.const 1)) (else (i32.const 2)))
      (then (i32.const 1))
      (else (i32.const 2)))
  )

Both hints survive a binary round-trip — proof they sit on distinct offsets (a
collision would drop one on decode).

  $ wax -f wasm m.wax -o m.wasm && wax -i wasm -f wat m.wasm
  (type (func (param i32) (result i32)))
  (func $f (param $x i32) (result i32)
    local.get $x
    (@metadata.code.branch_hint "\01")
    if (result i32)
      i32.const 1
    else
      i32.const 2
    end
    (@metadata.code.branch_hint "\01")
    if (result i32)
      i32.const 1
    else
      i32.const 2
    end
  )

(`wasm-tools validate` rejects the folded text above as a "duplicate annotation":
it binds a folded hint to the group's first instruction, so it collapses the two
onto the inner condition. That is a wasm-tools bug — the proposal's own
branch_hint.wast, binaryen, and wax all place the hint before the group and bind
it to the branch opcode; the binary is valid and wasmtime runs it. See
UPSTREAM-wasm-tools-branch-hint.md.)
