(* Wasm_of_ocaml compiler
 * http://www.ocsigen.org/js_of_ocaml/
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

type input = {
  module_name : string;
  file : string;
  code : string option;
  opt_source_map : Js_source_map.Standard.t option;
}

val f :
  ?filter_export:(string -> bool) ->
  ?distinct_named_types:bool ->
  input list ->
  output_file:string ->
  Js_source_map.t
(** [distinct_named_types] (default [false]) makes type deduplication
    name-aware: two structurally-equal types are coalesced into one output type
    only when they also share the same type name and field names; otherwise the
    later one is emitted as a separate, structurally-identical copy so its names
    survive. Off by default, matching wasm-merge's purely structural merge. *)

val get_instruction_offsets : filename:string -> string -> int list * int
