(type $ft (func (result i32)))
(func $callee (export "callee") (result i32) (i32.const 42))
(func $main (result (ref $ft)) (ref.func $callee))
