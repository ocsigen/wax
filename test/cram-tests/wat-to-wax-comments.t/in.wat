;; A leading comment
(module
  (type $ft (func (param i32) (result i32)))
  (table $t 1 funcref)
  ;; an indirect-call helper
  (func $call (param $i i32) (param $x i32) (result i32)
    local.get $x
    local.get $i
    call_indirect $t (type $ft))
  ;; a global
  (global $answer i32 (i32.const 42)))
;; End of file
