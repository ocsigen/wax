(module
  (type $resume (struct (field (ref eq))))
  (type $switch (func (param (ref $resume)) (result (ref eq))))
  (func $suspend (type $switch) (param (ref $resume)) (result (ref eq))
    (struct.get $resume 0 (local.get 0)))
  (elem declare func $suspend))
