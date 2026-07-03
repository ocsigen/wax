(module
  ;; A block label is kept even when no branch targets it, and a name that is
  ;; not a valid Wax identifier is salvaged where it can be: a leading digit
  ;; gets an underscore ($0_bytes -> '_0_bytes), and characters Wax rejects
  ;; (here the interior $) become underscores ($label$n -> 'label_n).
  (func $salvaged
    (block $0_bytes (nop))
    (block $label$n (nop)))
  ;; A name with two rejected characters in a row ($!!!) is not worth
  ;; salvaging, so the block stays bare, as does an anonymous one.
  (func $bare
    (block $!!! (nop))
    (block (nop))))
