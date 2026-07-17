(type $ft (func (result i32)))
(@if $FOO (@then (func $h)))
(func $callee (result i32) (i32.const 42))
(func $main (result (ref $ft)) (ref.func $callee))
