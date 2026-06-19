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

(type $float (struct (field $f f64)))
(type $block (array (mut (ref eq))))

(func $caml_gc_minor (export "caml_gc_minor")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_major (export "caml_gc_major")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_full_major (export "caml_gc_full_major")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_compaction (export "caml_gc_compaction")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_counters (export "caml_gc_counters")
  (param (ref eq)) (result (ref eq))
  (local $f (ref eq))
  (local.set $f (struct.new $float (f64.const 0)))
  (array.new_fixed $block 4 (ref.i31 (i32.const 0)) (local.get $f)
    (local.get $f) (local.get $f))
)

(func $caml_gc_stat (export "caml_gc_stat") (export "caml_gc_quick_stat")
  (param (ref eq)) (result (ref eq))
  (local $f (ref eq))
  (local.set $f (struct.new $float (f64.const 0)))
  (array.new_fixed $block 18 (ref.i31 (i32.const 0)) (local.get $f)
    (local.get $f) (local.get $f) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)))
)

(func $caml_gc_set (export "caml_gc_set") (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_get (export "caml_gc_get") (param (ref eq)) (result (ref eq))
  (array.new_fixed $block 12 (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0)) (ref.i31 (i32.const 0))
    (ref.i31 (i32.const 0)))
)

(func $caml_gc_huge_fallback_count (export "caml_gc_huge_fallback_count")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_major_slice (export "caml_gc_major_slice")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_major_bucket (export "caml_gc_major_bucket")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_major_credit (export "caml_gc_major_credit")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_minor_free (export "caml_gc_minor_free")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_gc_minor_words (export "caml_gc_minor_words")
  (param (ref eq)) (result (ref eq))
  (struct.new $float (f64.const 0))
)

(func $caml_final_register (export "caml_final_register")
  (param (ref eq) (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_final_register_called_without_value
  (export "caml_final_register_called_without_value")
  (param (ref eq) (ref eq)) (result (ref eq))
  ;; ZZZ Use FinalizationRegistry?
  (ref.i31 (i32.const 0))
)

(func $caml_final_release (export "caml_final_release")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_memprof_start (export "caml_memprof_start")
  (param (ref eq) (ref eq) (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_memprof_set (export "caml_memprof_set")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_memprof_stop (export "caml_memprof_stop")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_eventlog_pause (export "caml_eventlog_pause")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_eventlog_resume (export "caml_eventlog_resume")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
