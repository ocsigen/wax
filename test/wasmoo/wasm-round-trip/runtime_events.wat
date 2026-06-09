(type $block (array (mut (ref eq))))

(global $caml_custom_event_index (mut i32) (i32.const 0))
(func $caml_runtime_events_user_register
  (export

    "caml_runtime_events_user_register")
  (param $evname (ref eq)) (param $evtag (ref eq)) (param $evtype (ref eq))
  (result (ref eq))
  (global.set $caml_custom_event_index
    (i32.add (global.get $caml_custom_event_index) (i32.const 1)))
  (array.new_fixed $block 5 (ref.i31 (i32.const 0))
    (ref.i31 (global.get $caml_custom_event_index)) (local.get $evname)
    (local.get $evtag) (local.get $evtype))
)
(func $caml_runtime_events_user_resolve
  (export

    "caml_runtime_events_user_resolve")
  (param $x (ref eq)) (param $x_2 (ref eq)) (param $x_3 (ref eq))
  (result (ref eq))
  (ref.i31 (i32.const 0))
)
(func $caml_runtime_events_start
  (export

    "caml_runtime_events_start")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
(func $caml_runtime_events_pause
  (export

    "caml_runtime_events_pause")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
(func $caml_runtime_events_resume
  (export

    "caml_runtime_events_resume")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
(func $caml_ml_runtime_events_are_active
  (export

    "caml_ml_runtime_events_are_active")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
(func $caml_runtime_events_free_cursor
  (export

    ;; TODO: use Javascript function
    ;;(func (export "caml_runtime_events_create_cursor")
    ;;   (param (ref eq)) (result (ref eq))
    ;;   (ref.i31 (i32.const 0)))

    "caml_runtime_events_free_cursor")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
(func $caml_runtime_events_read_poll
  (export

    "caml_runtime_events_read_poll")
  (param $x (ref eq)) (param $x_2 (ref eq)) (param $x_3 (ref eq))
  (result (ref eq))
  (ref.i31 (i32.const 0))
)
(func $caml_ml_runtime_events_path
  (export

    "caml_ml_runtime_events_path")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
