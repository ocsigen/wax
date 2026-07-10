(module
  (type $ft (func (result funcref)))
  (type $ct (cont $ft))
  (type $tag_ft (func (result nullfuncref)))
  (tag $t (type $tag_ft))
  (func (export "f") (result funcref)
    (resume $ct (on $t switch) (ref.null $ct))))
