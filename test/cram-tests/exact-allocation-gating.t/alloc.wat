(module
  (rec (type $sa (sub (struct (field i32)))) (type $sb (sub $sa (struct (field i32) (field i64)))))
  (rec (type $sc (sub (struct (field i32)))) (type $sd (sub $sc (struct (field i32) (field i64)))))
  (rec (type $fa (sub (func (result (ref func))))) (type $fb (sub $fa (func (result (ref $fa))))))
  (rec (type $fc (sub (func (result (ref func))))) (type $fd (sub $fc (func (result (ref $fc))))))
  (func $f (type $fa) (result (ref func)) (unreachable))
  (func (export "alloc") (result i32) (ref.test (ref $sd) (struct.new_default $sa)))
  (func (export "reffunc") (result i32) (ref.test (ref $fd) (ref.func $f)))
  (elem declare func $f))
