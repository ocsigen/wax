;; RUN: wast --assert default --snapshot tests/snapshots %

;; A value type is `numtype | vectype | reftype`, and a reference type is either
;; an abstract heap type shorthand byte or the two-byte `0x64 heaptype` (`ref ht`)
;; / `0x63 heaptype` (`ref null ht`) forms. There is no bare type-index value
;; type, so a leading byte of `0x00` (a non-negative sLEB) is malformed.

;; type 0 = (func), type 1 = (func (param <0x00>)) — bare index used as a value type.
(assert_malformed
  (module binary
    "\00asm\01\00\00\00\01\08\02\60\00\00\60\01\00\00")
  "malformed reference type")

;; The same bug with an over-long LEB encoding of the bare index (`\ff\00` = 127).
;; The reftype discriminator is a single byte, so this must be rejected at decode
;; time rather than re-interpreted as a type index.
(assert_malformed
  (module binary
    "\00asm\01\00\00\00\01\09\02\60\00\00\60\01\ff\00\00")
  "malformed reference type")

;; Boundary: the legitimate concrete reftypes `0x63 <idx>` (`ref null $t`) and
;; `0x64 <idx>` (`ref $t`), where the index is an sLEB after the prefix byte, must
;; still be accepted.
(module binary
  "\00asm\01\00\00\00\01\0b\02\60\00\00\60\02\63\00\64\00\00")
