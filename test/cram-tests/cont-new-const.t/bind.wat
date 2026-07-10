(module
  (type $ft (func (param i32)))
  (type $ft2 (func))
  (type $ct (cont $ft))
  (type $ct2 (cont $ft2))
  (func $g (param i32))
  (global $c (ref $ct) (cont.new $ct (ref.func $g)))
  (global (ref $ct2) (cont.bind $ct $ct2 (i32.const 0) (global.get $c)))
  (elem declare func $g))
