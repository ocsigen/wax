;; The compilation-hints proposal's three custom sections. Companion to
;; custom/metadata.code.branch_hint/branch_hint.wast.
;;
;; No third-party implementation decodes these sections: wasm-tools 1.254 validates
;; a module carrying them and preserves them across its own print/parse round trip,
;; but renders all three as opaque (@custom …) payloads (it decodes only
;; branch_hint, which it implements). So the bytes are spelled out literally below,
;; with each field's meaning in the comment — the record of what the encoder is
;; supposed to produce, checked by hand against a wasm-tools extraction.
;;
;; What this file pins is the section STRUCTURE: the binary module must decode,
;; validate, and re-encode. It does not cross-check the literal bytes against the
;; text module above them — a payload byte changed in both places, or in the module
;; alone, still yields a valid module. The VALUES are pinned by
;; test/cram-tests/compilation-hints-*.t, which round-trip them back to source and
;; compare the text.

;; The text surface: all three sections on one function. instr_freq and
;; call_targets hint the same call_ref, so one instruction offset is keyed in two
;; sections at once — the case a decoder has to merge rather than let the second
;; hint displace the first.
(module
  (type $ft (func (param i32) (result i32)))
  (func $a (param i32) (result i32) (local.get 0))
  (func (export "go") (param $f (ref null $ft)) (param $x i32) (result i32)
    (@metadata.code.compilation_priority (priority 5) (run_once))
    (@metadata.code.instr_freq (freq 8))
    (@metadata.code.call_targets (target $a 0.73))
    (call_ref $ft (local.get $x) (local.get $f)))
)

;; The same module, byte for byte. Each section is
;;   vec(funcidx, vec(offset, len, payload))
;; and all three precede the code section, as they must: the offsets they carry are
;; only known once the bodies are encoded.
;;
;;   instr_freq            01 | 01 | 01 | 05 01 23
;;                         one entry, funcidx 1, one hint, offset 5, one byte 0x23
;;                         = 35 = floor(log2 8) + 32, i.e. (freq 8)
;;   call_targets          01 | 01 | 01 | 05 02 00 49
;;                         funcidx 1, offset 5 (the SAME instruction), two bytes
;;                         = funcidx 0 at 0x49 = 73%, i.e. (target $a 0.73)
;;   compilation_priority  01 | 01 | 01 | 00 02 05 7f
;;                         funcidx 1, offset 0 (the function itself), two bytes
;;                         = priority 5, optimization 127, i.e. (priority 5) (run_once)
(module binary
  "\00asm" "\01\00\00\00"
  "\01\0d\02\60\01\7f\01\7f\60\02\63\00\7f\01\7f"
  "\03\03\02\00\01"
  "\07\06\01\02\67\6f\00\01"
  "\00\1f\18\6d\65\74\61\64\61\74\61\2e\63\6f\64\65\2e\69\6e\73\74\72\5f\66\72\65\71\01\01\01\05\01\23"
  "\00\22\1a\6d\65\74\61\64\61\74\61\2e\63\6f\64\65\2e\63\61\6c\6c\5f\74\61\72\67\65\74\73\01\01\01\05\02\00\49"
  "\00\2a\22\6d\65\74\61\64\61\74\61\2e\63\6f\64\65\2e\63\6f\6d\70\69\6c\61\74\69\6f\6e\5f\70\72\69\6f\72\69\74\79\01\01\01\00\02\05\7f"
  "\0a\0f\02\04\00\20\00\0b\08\00\20\01\20\00\14\00\0b"
)

;; A frequency guides inlining, loop unrolling and block deferral, so it is only
;; meaningful on a call or a control instruction.
(assert_invalid_custom
  (module
    (func (export "f") (result i32)
      (@metadata.code.instr_freq (freq 4))
      (i32.const 0))
  )
  "@metadata.code.instr_freq annotation: invalid target"
)

;; A target list only says something when the callee is not already known, so a
;; direct call cannot carry one.
(assert_invalid_custom
  (module
    (func $a (result i32) (i32.const 0))
    (func (export "f") (result i32)
      (@metadata.code.call_targets (target $a 0.5))
      (call $a))
  )
  "@metadata.code.call_targets annotation: invalid target"
)

;; The listed frequencies must total at most 100%: a shortfall is how the hint says
;; other, unlisted targets take the remainder, so exceeding it is meaningless.
(assert_invalid_custom
  (module
    (type $ft (func (result i32)))
    (func $a (type $ft) (i32.const 0))
    (func $b (type $ft) (i32.const 1))
    (table $t funcref (elem $a $b))
    (func (export "f") (result i32)
      (@metadata.code.call_targets (target $a 0.8) (target $b 0.5))
      (call_indirect $t (type $ft) (i32.const 0)))
  )
  "@metadata.code.call_targets annotation: frequencies over 100%"
)
