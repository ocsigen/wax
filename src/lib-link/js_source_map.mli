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

module Source_content : sig
  type t

  val create : string -> t
  val of_stringlit : [ `Stringlit of string ] -> t
end

type map =
  | Gen of { gen_line : int; gen_col : int }
  | Gen_Ori of {
      gen_line : int;
      gen_col : int;
      ori_source : int;
      ori_line : int;
      ori_col : int;
    }
  | Gen_Ori_Name of {
      gen_line : int;
      gen_col : int;
      ori_source : int;
      ori_line : int;
      ori_col : int;
      ori_name : int;
    }

module Offset : sig
  type t = { gen_line : int; gen_column : int }
end

module Mappings : sig
  type t

  val empty : t
  val is_empty : t -> bool
  val of_string_unsafe : string -> t
  val to_string : t -> string
end

module Standard : sig
  type t = {
    version : int;
    file : string option;
    sourceroot : string option;
    sources : string list;
    sources_content : Source_content.t option list option;
    names : string list;
    mappings : Mappings.t;
    ignore_list : string list;
  }

  val of_file : ?tmp_buf:Buffer.t -> string -> t
end

module Index : sig
  type section = { offset : Offset.t; map : Standard.t }
  type t = { version : int; file : string option; sections : section list }
end

type t = Standard of Standard.t | Index of Index.t

val to_file : ?rewrite_paths:bool -> t -> string -> unit

type resize_data = {
  mutable i : int;
  mutable pos : int array;
  mutable delta : int array;
}

val is_empty : Standard.t -> bool
val resize_mappings : resize_data -> string -> string
val resize : resize_data -> Standard.t -> Standard.t
val concatenate : (int * Standard.t) list -> t
