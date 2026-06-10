(module
  (rec
    (type $sft (func (param (ref null $sct)) (result i32)))
    (type $sct (cont $sft)))
  (tag $swap (param i32) (result i32))
  (func $f (type $sft) (param (ref null $sct)) (result i32) (i32.const 0))
  (func $onsw (param $k (ref null $sct)) (result i32)
    (resume $sct (on $swap switch) (local.get $k) (cont.new $sct (ref.func $f))))
  (elem declare func $f))
