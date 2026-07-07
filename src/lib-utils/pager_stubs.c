#include <caml/mlvalues.h>
#include <caml/fail.h>

CAMLprim value wax_pager_capture_stdout(value unit) {
  (void)unit;
  caml_failwith("wax_pager_capture_stdout: not available on this backend");
}

CAMLprim value wax_pager_flush_captured(value unit) {
  (void)unit;
  caml_failwith("wax_pager_flush_captured: not available on this backend");
}
