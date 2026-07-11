(* Js_of_ocaml compiler
 * http://www.ocsigen.org/js_of_ocaml/
 * Copyright (C) 2013 Hugo Heuzard
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

(* A single (non-indexed) source map, as read from a [.map] file. Opaque: the
   linker only carries it from [of_file] through [resize] to [concatenate]. *)
module Standard : sig
  type t

  val of_file : ?tmp_buf:Buffer.t -> string -> t
end

(* The linked output's source map: the indexed form produced by [concatenate]. *)
type t

val to_file : t -> string -> unit

(* A sequence of [(pos, delta)] byte-shift entries with strictly increasing
   [pos], describing how the code section grew/shrank when instructions were
   re-encoded during linking. Built imperatively by the code scan, hence the
   mutable growable arrays; [i] is the number of live entries. *)
type resize_data = {
  mutable i : int;
  mutable pos : int array;
  mutable delta : int array;
}

val is_empty : Standard.t -> bool

(* [resize_mappings data m] rewrites the VLQ "mappings" string [m], shifting each
   generated column by the cumulative [data] delta at that column and dropping a
   segment whose column would become negative (folding its source/name deltas
   into the next survivor). Exposed for testing. *)
val resize_mappings : resize_data -> string -> string
val resize : resize_data -> Standard.t -> Standard.t

(* Combine per-module maps, each offset by its code-section start, into one
   indexed source map for the linked output. *)
val concatenate : (int * Standard.t) list -> t
