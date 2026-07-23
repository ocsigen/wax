# wasm-tools: folded branch-hint annotation bound to the wrong instruction

**Tools:** `wasm-tools 1.254.0` (bug), `binaryen 130` and `wax` (correct),
`wasmtime 25.0.3`.
**Component:** the WAT text parser's offset resolution for
`(@metadata.code.branch_hint …)` on a **folded** branch instruction.

## Summary

The branch-hinting proposal's text convention places the annotation *before* the
folded group it hints — `(@hint) (if <cond> (then …) (else …))` — and binds it to
the branch (`if`/`br_if`/…) **opcode**. This is what the proposal's own test file
[`test/custom/metadata.code.branch_hint/branch_hint.wast`][spec] does (the
`nested` function), and what binaryen and wax both emit and read.

`wasm-tools` instead binds a folded annotation *positionally* to the **first
instruction emitted** by the folded group — the condition's first instruction —
so it targets the wrong instruction (typically a `local.get`, a non-branch
instruction the spec's own `assert_invalid_custom` case declares an "invalid
target"). Two downstream symptoms:

1. Single hint → silently bound to the condition, not the branch.
2. Two hinted branches sharing a leading operand (a hinted `if` used as the
   *condition* of another hinted `if`) → both bound to the same offset →
   `wasm-tools validate` falsely rejects "duplicate annotation".

[spec]: https://github.com/WebAssembly/branch-hinting/blob/main/test/custom/metadata.code.branch_hint/branch_hint.wast

## Proof, against the proposal's own test file

The `nested` function in `branch_hint.wast` writes:

```wat
(@metadata.code.branch_hint "\00")
(if (result i32) (local.get 0)
  (then … ))
```

Encode it two ways and dump the `metadata.code.branch_hint` section. The function
body begins with `local_get 0` (2 bytes) then the `if` opcode:

```
 0x88 | 00    | 0 local blocks        # func_offset 0
 0x89 | 20 00 | local_get 0           # func_offset 1
 0x8b | 04 7f | if                    # func_offset 3   <- the branch
```

| Encoder | first hint `func_offset` | targets |
|---------|--------------------------|---------|
| **wax** / **binaryen** | 3 | the `if` (correct) |
| **wasm-tools** (`wasm-tools parse`) | 1 | `local_get 0` — a non-branch instruction |

The same +2 (one `local.get`) discrepancy holds for all three folded hints in the
function (wax 3/30/56 vs wasm-tools 1/28/54). By the spec's own
`assert_invalid_custom` — a hint on `i32.eq` is an "invalid target" — binding to
`local.get` is wrong; `wasm-tools` nonetheless accepts it, so it both mis-targets
and fails to diagnose.

## The false "duplicate", same root cause

```wat
(module
 (func $f (export "f") (param $x i32) (result i32)
  (@metadata.code.branch_hint "\01")
  (if (result i32)
    (@metadata.code.branch_hint "\01")
    (if (result i32) (local.get $x) (then (i32.const 1)) (else (i32.const 2)))
    (then (i32.const 1))
    (else (i32.const 2)))))
```

Here the two hints target two distinct `if` opcodes (wax/binaryen encode them at
offsets 3 and 11; the binary validates and round-trips). But `wasm-tools`, binding
both positionally to the shared inner condition, collapses them:

```
$ wasm-tools validate --features all repro.wat
error: @metadata.code.branch_hint annotation: duplicate annotation
```

binaryen assembles it and wasmtime runs it (`--invoke f` returns 1).

## Root cause: index-based attachment records the wrong instruction

In `crates/wast/src/core/expr.rs`, the annotation's target is recorded *eagerly*
as the index of the next instruction pushed. For the flat form (`… (@h) if`) that
is the `if`. For the folded form (`(@h) (if (cond) …)`) the operands are pushed
first, so the hint lands on the first operand (the condition) instead of the
branch. There is **no check that the target is a branch instruction** — the only
branch-hint validations are the structural byte checks in
`crates/wasmparser/src/readers/core/branch_hinting.rs` and the duplicate check in
`parse_branch_hint` — so the mis-binding is never diagnosed; the collapsed nested
case surfaces only because the duplicate check runs on the (wrong) offsets.
`wasm-tools validate <module>` inspects no branch-hint targets at all.

## Suggested fix

Defer the index assignment: keep the parsed annotation pending and attach it to
the head instruction of the following flat or folded form when that instruction is
actually pushed. This binds the hint to the branch opcode — the offset the binary
reader uses and the one implied by the `nested` example in `branch_hint.wast`.

## Status

Fixed in this checkout of wasm-tools: `1177dc78` (defer the index, attach to the
head instruction — also accepting the annotation inside the folded form) and
`0ca11988` (print the annotation before the folded instruction). This report is
retained for reference / upstreaming; released `wasm-tools` (1.254.0) still has
the bug, so the fuzz oracle keeps tolerating the false "duplicate annotation".

## wax status

wax's folded output is correct (matches binaryen and the spec) and is left as-is.
wax also now **parses** the folded-operand placement (a hinted `if` as a
condition), so its own output and binaryen's round-trip through it. The fuzz
oracle (`fuzz/oracle.sh`) suppresses the `wasm-tools validate` "duplicate
annotation" false-positive until a fixed `wasm-tools` is released.
