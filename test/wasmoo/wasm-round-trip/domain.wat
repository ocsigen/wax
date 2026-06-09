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

(type $block (array (mut (ref eq))))
(type $function_1 (func (param (ref eq) (ref eq)) (result (ref eq))))
(type $closure (sub (struct (field $f (ref $function_1))))) (;(field i32);)

(func $caml_atomic_cas (export "caml_atomic_cas")
  (param $ref (ref eq)) (param $o (ref eq)) (param $n (ref eq))
  (result (ref eq))
  (local $b (ref $block))
  (local.set $b (ref.cast (ref $block) (local.get $ref)))
  (if (result (ref eq))
    (ref.eq (array.get $block (local.get $b) (i32.const 1)) (local.get $o))
    (then
      (array.set $block (local.get $b) (i32.const 1) (local.get $n))
      (ref.i31 (i32.const 1)))
    (else (ref.i31 (i32.const 0))))
)

(func $caml_atomic_load (export "caml_atomic_load")
  (param $x (ref eq)) (result (ref eq))
  (array.get $block (ref.cast (ref $block) (local.get $x)) (i32.const 1))
)

(func $caml_atomic_fetch_add (export "caml_atomic_fetch_add")
  (param $ref (ref eq)) (param $i (ref eq)) (result (ref eq))
  (local $b (ref $block)) (local $old (ref eq))
  (local.set $b (ref.cast (ref $block) (local.get $ref)))
  (local.set $old (array.get $block (local.get $b) (i32.const 1)))
  (array.set $block (local.get $b) (i32.const 1)
    (ref.i31
      (i32.add (i31.get_s (ref.cast (ref i31) (local.get $old)))
        (i31.get_s (ref.cast (ref i31) (local.get $i))))))
  (local.get $old)
)

(func $caml_atomic_exchange (export "caml_atomic_exchange")
  (param $ref (ref eq)) (param $v (ref eq)) (result (ref eq))
  (local $b (ref $block)) (local $r (ref eq))
  (local.set $b (ref.cast (ref $block) (local.get $ref)))
  (local.set $r (array.get $block (local.get $b) (i32.const 1)))
  (array.set $block (local.get $b) (i32.const 1) (local.get $v))
  (local.get $r)
)

(global $caml_domain_dls (mut (ref eq))
  (array.new_fixed $block 1 (ref.i31 (i32.const 0)))
)

(func $caml_domain_dls_set (export "caml_domain_dls_set")
  (param $a (ref eq)) (result (ref eq))
  (global.set $caml_domain_dls (local.get $a))
  (ref.i31 (i32.const 0))
)

(func $caml_domain_dls_compare_and_set
  (export "caml_domain_dls_compare_and_set")
  (param $old (ref eq)) (param $new (ref eq)) (result (ref eq))
  (if (result (ref eq))
    (ref.eq (global.get $caml_domain_dls) (local.get $old))
    (then
      (global.set $caml_domain_dls (local.get $new))
      (ref.i31 (i32.const 1)))
    (else (ref.i31 (i32.const 0))))
)

(func $caml_domain_dls_get (export "caml_domain_dls_get")
  (param $x (ref eq)) (result (ref eq))
  (global.get $caml_domain_dls)
)

(global $caml_ml_domain_unique_token (ref eq)
  (array.new_fixed $block 1 (ref.i31 (i32.const 0)))
)

(func $caml_ml_domain_unique_token_2 (export "caml_ml_domain_unique_token")
  (param $x (ref eq)) (result (ref eq))
  (global.get $caml_ml_domain_unique_token)
)

(func $caml_ml_domain_set_name (export "caml_ml_domain_set_name")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $caml_recommended_domain_count (export "caml_recommended_domain_count")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 1))
)

(global $caml_domain_id (export "caml_domain_id") (mut i32) (i32.const 0))
(global $caml_domain_latest_id (export "caml_domain_latest_id") (mut i32)
  (i32.const 1)
)

(func $caml_ml_domain_id (export "caml_ml_domain_id")
  (export "caml_ml_domain_index") (param $x (ref eq)) (result (ref eq))
  (ref.i31 (global.get $caml_domain_id))
)

(func $caml_ml_domain_cpu_relax (export "caml_ml_domain_cpu_relax")
  (param $x (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
