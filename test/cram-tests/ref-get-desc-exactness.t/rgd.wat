(module
  (rec
    (type $a (descriptor $b) (struct))
    (type $b (describes $a) (struct)))
  ;; exact operand -> exact descriptor
  (func (export "exact") (param (ref (exact $a))) (result (ref (exact $b)))
    (ref.get_desc $a (local.get 0)))
  ;; a bottom (null) operand fits the exact operand type -> exact descriptor
  (func (export "null") (result (ref (exact $b)))
    (ref.get_desc $a (ref.null none)))
  ;; inexact operand -> inexact descriptor
  (func (export "inexact") (param (ref $a)) (result (ref $b))
    (ref.get_desc $a (local.get 0))))
