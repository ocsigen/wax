(module
   (import "js" "wax_pager_capture_stdout"
      (func $capture (param (ref eq)) (result (ref eq))))
   (import "js" "wax_pager_flush_captured"
      (func $flush (param (ref eq)) (result (ref eq))))

   (func (export "wax_pager_capture_stdout")
      (param (ref eq)) (result (ref eq))
      (call $capture (local.get 0)))

   (func (export "wax_pager_flush_captured")
      (param (ref eq)) (result (ref eq))
      (call $flush (local.get 0))))
