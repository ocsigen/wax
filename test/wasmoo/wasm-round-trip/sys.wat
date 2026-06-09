;; Wasm_of_ocaml runtime support
;; http://www.ocsigen.org/js_of_ocaml/
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Lesser General Public License as published by
;; the Free Software Foundation, with linking exception;
;; either version 2.1 of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Lesser General Public License for more details.
;;
;; You should have received a copy of the GNU Lesser General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

(import "bindings" "ta_length"
  (func $ta_length (param (ref extern)) (result i32))
)
(import "bindings" "ta_get_i32"
  (func $ta_get_i32 (param (ref extern) i32) (result i32))
) (import "bindings" "random_seed" (func $random_seed (result (ref extern))))
(import "jslib" "unwrap" (func $unwrap (param (ref eq)) (result anyref)))
(import "jslib" "wrap" (func $wrap (param anyref) (result (ref eq))))
(import "jslib" "caml_jsstring_of_string"
  (func $caml_jsstring_of_string (param (ref eq)) (result (ref eq)))
)
(import "jslib" "caml_string_of_jsstring"
  (func $caml_string_of_jsstring (param (ref eq)) (result (ref eq)))
)
(import "jslib" "caml_js_to_string_array"
  (func $caml_js_to_string_array (param $a (ref extern)) (result (ref eq)))
)
(import "jslib" "caml_js_meth_call"
  (func $caml_js_meth_call
    (param (ref eq) (ref eq) (ref eq)) (result (ref eq)))
)
(import "fail" "caml_raise_sys_error"
  (func $caml_raise_sys_error (param (ref eq)))
) (import "fail" "caml_raise_not_found" (func $caml_raise_not_found))
(import "bindings" "argv" (func $argv (result (ref extern))))
(import "bindings" "system" (func $system (param anyref) (result (ref eq))))
(import "bindings" "getenv" (func $getenv (param anyref) (result anyref)))
(import "bindings" "time" (func $time (result f64)))
(import "bindings" "array_length"
  (func $array_length (param (ref extern)) (result i32))
)
(import "bindings" "array_get"
  (func $array_get (param (ref extern) i32) (result anyref))
)
(import "fail" "javascript_exception"
  (tag $javascript_exception (param externref))
)
(import "jsstring" "jsstring_test"
  (func $jsstring_test (param anyref) (result i32))
)

(type $block (array (mut (ref eq)))) (type $string (array (mut i8)))
(type $float (struct (field $f f64)))

(tag $ocaml_exit (export "ocaml_exit") (param i32))

(func $caml_sys_exit (export "caml_sys_exit")
  (param $x (ref eq)) (result (ref eq))
  (throw $ocaml_exit (i31.get_s (ref.cast (ref i31) (local.get $x))))
)
(func $caml_sys_getenv (export "caml_sys_getenv")
  (export

    "caml_sys_unsafe_getenv")
  (param $x (ref eq)) (result (ref eq))
  (local $res anyref)
  (local.set $res
    (call $getenv
      (call $unwrap (call $caml_jsstring_of_string (local.get $x)))))
  (if (i32.eqz (call $jsstring_test (local.get $res)))
    (then (call $caml_raise_not_found)))
  (return_call $caml_string_of_jsstring (call $wrap (local.get $res)))
)

(func $caml_sys_argv (export "caml_sys_argv")
  (param $x (ref eq)) (result (ref eq))
  ;; ZZZ
  (call $caml_js_to_string_array (call $argv))
)

(func $caml_sys_executable_name (export "caml_sys_executable_name")
  (param $x (ref eq)) (result (ref eq))
  (array.get $block
    (ref.cast (ref $block) (call $caml_js_to_string_array (call $argv)))
    (i32.const 1))
)
(func $caml_sys_time (export "caml_sys_time")
  (export

    "caml_sys_time_include_children")
  (param $x (ref eq)) (result (ref eq))
  (struct.new $float (f64.mul (call $time) (f64.const 0.001)))
)

(func $caml_sys_system_command (export "caml_sys_system_command")
  (param $x (ref eq)) (result (ref eq))
  ;; ZZZ
  (try (result (ref eq))
    (do
      (return
        (call $system
          (call $unwrap (call $caml_jsstring_of_string (local.get $x))))))
    (catch $javascript_exception
      (call $caml_handle_sys_error)
      (return (ref.i31 (i32.const 0)))))
)

(func $caml_sys_random_seed (export "caml_sys_random_seed")
  (param $x (ref eq)) (result (ref eq))
  (local $r (ref extern)) (local $n i32) (local $a (ref $block))
  (local $i i32)
  (local.set $r (call $random_seed))
  (local.set $n (call $ta_length (local.get $r)))
  (local.set $a
    (array.new $block (ref.i31 (i32.const 0))
      (i32.add (local.get $n) (i32.const 1))))
  (local.set $i (i32.const 0))
  (loop $loop
    (if (i32.lt_u (local.get $i) (local.get $n))
      (then
        (array.set $block (local.get $a)
          (i32.add (local.get $i) (i32.const 1))
          (ref.i31 (call $ta_get_i32 (local.get $r) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))) ;; 'loop
  (local.get $a)
)

(func $caml_sys_const_bigendian (export "caml_sys_const_bigendian")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_sys_const_word_size (export "caml_sys_const_word_size")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 32))
)

(func $caml_sys_const_int_size (export "caml_sys_const_int_size")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 31))
)

(func $caml_sys_const_max_wosize (export "caml_sys_const_max_wosize")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0xfffffff))
)

(func $caml_sys_const_ostype_unix (export "caml_sys_const_ostype_unix")
  (param $x (ref eq)) (result (ref eq))
  ;; ZZZ
  (ref.i31 (i32.const 1))
)

(func $caml_sys_const_ostype_win32 (export "caml_sys_const_ostype_win32")
  (param $x (ref eq)) (result (ref eq))
  ;; ZZZ
  (ref.i31 (i32.const 0))
)

(func $caml_sys_const_ostype_cygwin (export "caml_sys_const_ostype_cygwin")
  (param $x (ref eq)) (result (ref eq))
  ;; ZZZ
  (ref.i31 (i32.const 0))
)

(data $Unix "Unix")

(func $caml_sys_get_config (export "caml_sys_get_config")
  (param $x (ref eq)) (result (ref eq))
  ;; ZZZ
  ;; (call $log_js (string.const "caml_sys_get_config"))
  (array.new_fixed $block 4 (ref.i31 (i32.const 0))
    (array.new_data $string $Unix (i32.const 0) (i32.const 4))
    (ref.i31 (i32.const 32)) (ref.i31 (i32.const 0)))
)

(func $caml_sys_isatty (export "caml_sys_isatty")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_runtime_variant (export "caml_runtime_variant")
  (param $x (ref eq)) (result (ref eq))
  (array.new_fixed $string 0)
)

(func $caml_runtime_parameters (export "caml_runtime_parameters")
  (param $x (ref eq)) (result (ref eq))
  (array.new_fixed $string 0)
)

(func $caml_install_signal_handler (export "caml_install_signal_handler")
  (param $x (ref eq)) (param $x_2 (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(global $caml_runtime_warnings (mut i32) (i32.const 0))

(func $caml_ml_enable_runtime_warnings
  (export "caml_ml_enable_runtime_warnings")
  (param $x (ref eq)) (result (ref eq))
  (global.set $caml_runtime_warnings
    (i31.get_u (ref.cast (ref i31) (local.get $x))))
  (ref.i31 (i32.const 0))
)

(func $caml_ml_runtime_warnings_enabled
  (export "caml_ml_runtime_warnings_enabled")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (global.get $caml_runtime_warnings))
)

(data $toString "toString")

(func $caml_handle_sys_error (export "caml_handle_sys_error")
  (param $exn externref)
  (call $caml_raise_sys_error
    (call $caml_string_of_jsstring
      (call $caml_js_meth_call
        (call $wrap (any.convert_extern (local.get $exn)))
        (array.new_data $string $toString (i32.const 0) (i32.const 8))
        (array.new_fixed $block 1 (ref.i31 (i32.const 0))))))
)
