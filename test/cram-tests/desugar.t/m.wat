(module
  (type $w (array (mut i16)))
  (type $b (array (mut i8)))
  (@string $sg "hi")
  (func (export "ch") (result i32) (@char "😀"))
  (func (export "s") (result (ref $b)) (@string $b "yo"))
  (func (export "w") (result (ref $w)) (@string $w "é😀")))
