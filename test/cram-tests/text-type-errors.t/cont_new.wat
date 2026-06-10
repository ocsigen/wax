(module
  (rec
    (type $ft (func (result i32)))
    (type $ct (cont $ft)))
  (func (param (ref null $ft)) (result i32)
    (cont.new $ct (local.get 0))))
