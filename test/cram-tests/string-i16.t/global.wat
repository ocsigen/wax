(module
  (type $w (array (mut i16)))
  (@string $wide $w "hé😀")
  (@string $narrow "hi")
  (func (export "g") (result (ref $w)) (global.get $wide)))
