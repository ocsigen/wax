(module
  (type $ft (func (result i64)))
  (type $ct (cont $ft))
  (type $tag_ft (func (result i32)))
  (tag $t (type $tag_ft))
  (func (export "f") (result i64)
    (resume $ct (on $t switch) (ref.null $ct))))
