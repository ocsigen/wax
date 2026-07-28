(module
  (type $used (struct (field $a i32)))
  (type $unused (struct (field i32)))
  (type $_ignored (struct))
  (type $reached_via_field (struct (field i32)))
  (type $holder (struct (field (ref null $reached_via_field))))
  (type $dead_target (struct (field i64)))
  (type $dead_holder (struct (field (ref null $dead_target))))
  ;; dead cycle: the two only name each other
  (rec
    (type $rec_dead_a (struct (field (ref null $rec_dead_b))))
    (type $rec_dead_b (struct (field (ref null $rec_dead_a)))))
  ;; live cycle: reached through the exported function's signature
  (rec
    (type $rec_live_a (struct (field (ref null $rec_live_b))))
    (type $rec_live_b (struct (field (ref null $rec_live_a)))))
  (type $only_in_dead_body (struct (field i32)))
  (func $dead (result (ref null $only_in_dead_body))
    (ref.null $only_in_dead_body))
  (func (export "f")
    (param $h (ref null $holder)) (param $r (ref null $rec_live_a))
    (result i32)
    (struct.get $used $a (struct.new $used (i32.const 1)))))
