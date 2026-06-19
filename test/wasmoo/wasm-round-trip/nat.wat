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

(func $initialize_nat (export "initialize_nat")
  (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $create_nat (export "create_nat") (param (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $set_to_zero_nat (export "set_to_zero_nat")
  (param (ref eq) (ref eq) (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $set_digit_nat (export "set_digit_nat")
  (param (ref eq) (ref eq) (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)

(func $incr_nat (export "incr_nat")
  (param (ref eq) (ref eq) (ref eq) (ref eq)) (result (ref eq))
  (ref.i31 (i32.const 0))
)
