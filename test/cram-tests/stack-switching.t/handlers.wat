(module
  ;; resume with an on-label handler
  (type $ft (func (param i32) (result i32)))
  (type $ct (cont $ft))
  (tag $yield (param i32) (result i32))
  (func $handle (param $k0 (ref null $ct)) (result i32)
    (block $h (result i32 (ref $ct))
      (resume $ct (on $yield $h) (i32.const 1) (local.get $k0))
      (return))
    (drop)
    (return))
  ;; switch between two continuations
  (rec
    (type $ft1 (func (param (ref null $ct2)) (result i32)))
    (type $ct1 (cont $ft1))
    (type $ft2 (func (param i32) (result i32)))
    (type $ct2 (cont $ft2)))
  (tag $e (result i32))
  (func $sw (param $k (ref null $ct1)) (result i32)
    (switch $ct1 $e (local.get $k)))
  ;; resume with an on-switch handler
  (rec
    (type $sft (func (param (ref null $sct)) (result i32)))
    (type $sct (cont $sft)))
  (tag $swap (result i32))
  (func $f (type $sft) (param (ref null $sct)) (result i32) (i32.const 0))
  (func $onsw (param $k (ref null $sct)) (result i32)
    (resume $sct (on $swap switch) (local.get $k) (cont.new $sct (ref.func $f))))
  (elem declare func $f))
