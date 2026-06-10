(module
  (rec (type $ft (func (param i32) (result i32))) (type $ct (cont $ft)))
  (func (result i32)
    (resume $ct (i32.const 0) (i32.const 1))))
