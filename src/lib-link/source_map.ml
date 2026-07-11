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

open! Stdlib
module List = ListLabels
module Array = ArrayLabels
module String = StringLabels
module IntSet = Set.Make (Int)
module StringSet = Set.Make (String)

let list_string_assoc name l =
  List.find_map
    ~f:(fun (name', value) ->
      if String.equal name name' then Some value else None)
    l

let list_is_empty = function [] -> true | _ -> false

module Source_content = struct
  type t = Sc_as_Stringlit of string

  let of_stringlit (`Stringlit s) = Sc_as_Stringlit s
  let to_json (Sc_as_Stringlit s) = `Stringlit s
end

module Offset = struct
  type t = { gen_line : int; gen_column : int }
end

module Mappings = struct
  type t = Uninterpreted of string

  let empty = Uninterpreted ""
  let is_empty (Uninterpreted s) = String.equal s ""
  let of_string_unsafe s = Uninterpreted s
  let to_string (Uninterpreted s) = s
end

module Standard = struct
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

  let version_is_valid = function 3 -> true | _ -> false
  let invalid () = invalid_arg "Source_map.of_json"

  let string_of_stringlit ?tmp_buf (`Stringlit s) =
    match Yojson.Safe.from_string ?buf:tmp_buf s with
    | `String s -> s
    | _ -> invalid ()

  let int_of_intlit (`Intlit s) =
    match Yojson.Safe.from_string s with `Int s -> s | _ -> invalid ()

  let stringlit name rest : [ `Stringlit of string ] option =
    match list_string_assoc name rest with
    | Some (`Stringlit _ as s) -> Some s
    | Some `Null -> None
    | Some _ -> invalid ()
    | None -> None

  let list_stringlit name rest =
    match list_string_assoc name rest with
    | Some (`List l) ->
        Some
          (List.map l ~f:(function `Stringlit _ as s -> s | _ -> invalid ()))
    | Some _ -> invalid ()
    | None -> None

  let list_stringlit_opt name rest =
    match list_string_assoc name rest with
    | Some (`List l) ->
        Some
          (List.map l ~f:(function
            | `Stringlit _ as s -> Some s
            | `Null -> None
            | _ -> invalid ()))
    | Some _ -> invalid ()
    | None -> None

  let list_intlit name rest =
    match list_string_assoc name rest with
    | Some (`List l) ->
        Some (List.map l ~f:(function `Intlit _ as s -> s | _ -> invalid ()))
    | Some _ -> invalid ()
    | None -> None

  let json t =
    let stringlit s = `Stringlit (Yojson.Safe.to_string (`String s)) in
    `Assoc
      (List.filter_map
         ~f:(fun (name, v) ->
           match v with None -> None | Some v -> Some (name, v))
         [
           ("version", Some (`Intlit (string_of_int t.version)));
           ( "file",
             Option.map
               (fun s -> `Stringlit (Yojson.Safe.to_string (`String s)))
               t.file );
           ( "sourceRoot",
             Option.map
               (fun s -> `Stringlit (Yojson.Safe.to_string (`String s)))
               t.sourceroot );
           ( "sources",
             Some (`List (List.map t.sources ~f:(fun s -> stringlit s))) );
           ( "sourcesContent",
             Option.map
               (fun l ->
                 `List
                   (List.map l ~f:(function
                     | None -> `Null
                     | Some s -> Source_content.to_json s)))
               t.sources_content );
           ("names", Some (`List (List.map t.names ~f:(fun s -> stringlit s))));
           ("mappings", Some (stringlit (Mappings.to_string t.mappings)));
           ( "ignoreList",
             if not (list_is_empty t.ignore_list) then
               let ignore_set = StringSet.of_list t.ignore_list in
               Some
                 (`List
                    (List.filter_map
                       (List.mapi
                          ~f:(fun i nm ->
                            if StringSet.mem nm ignore_set then
                              Some (`Intlit (string_of_int i))
                            else None)
                          t.sources)
                       ~f:(fun x -> x)))
             else None );
         ])

  let of_json ?tmp_buf (json : Yojson.Raw.t) =
    match json with
    | `Assoc (("version", `Intlit version) :: rest)
      when version_is_valid (int_of_string version) ->
        let string name json =
          Option.map
            (fun s -> string_of_stringlit ?tmp_buf s)
            (stringlit name json)
        in
        let file = string "file" rest in
        let sourceroot = string "sourceRoot" rest in
        let names =
          match list_stringlit "names" rest with
          | None -> []
          | Some l -> List.map ~f:string_of_stringlit l
        in
        let sources =
          match list_stringlit "sources" rest with
          | None -> []
          | Some l -> List.map ~f:string_of_stringlit l
        in
        let sources_content =
          match list_stringlit_opt "sourcesContent" rest with
          | None -> None
          | Some l ->
              Some
                (List.map l ~f:(function
                  | None -> None
                  | Some s -> Some (Source_content.of_stringlit s)))
        in
        let mappings =
          match stringlit "mappings" rest with
          | None -> Mappings.empty
          | Some s -> Mappings.of_string_unsafe (string_of_stringlit ?tmp_buf s)
        in
        let ignore_list =
          let s =
            IntSet.of_list
              (List.map ~f:int_of_intlit
                 (Option.value ~default:[] (list_intlit "ignoreList" rest)))
          in
          List.filter_map
            (List.mapi
               ~f:(fun i nm -> if IntSet.mem i s then Some nm else None)
               sources)
            ~f:(fun x -> x)
        in
        {
          version = int_of_string version;
          file;
          sourceroot;
          names;
          sources_content;
          sources;
          mappings;
          ignore_list;
        }
    | _ -> invalid ()

  let of_file ?tmp_buf f =
    of_json ?tmp_buf (Yojson.Raw.from_file ?buf:tmp_buf f)
end

module Index = struct
  type section = { offset : Offset.t; map : Standard.t }
  type t = { version : int; file : string option; sections : section list }

  let json t =
    `Assoc
      (List.filter_map
         ~f:(fun (name, v) ->
           match v with None -> None | Some v -> Some (name, v))
         [
           ("version", Some (`Intlit (string_of_int t.version)));
           ( "file",
             Option.map
               (fun s -> `Stringlit (Yojson.Safe.to_string (`String s)))
               t.file );
           ( "sections",
             Some
               (`List
                  (List.map
                     ~f:(fun
                         { offset = { Offset.gen_line; gen_column }; map } ->
                       `Assoc
                         [
                           ( "offset",
                             `Assoc
                               [
                                 ("line", `Intlit (string_of_int gen_line));
                                 ("column", `Intlit (string_of_int gen_column));
                               ] );
                           ("map", Standard.json map);
                         ])
                     t.sections)) );
         ])

  let to_file m file = Yojson.Raw.to_file file (json m)
end

(* The linker only ever produces the indexed form (see [concatenate]). *)
type t = Index.t

let to_file = Index.to_file

type resize_data = {
  mutable i : int;
  mutable pos : int array;
  mutable delta : int array;
}

type input = Vlq64.input = { string : string; mutable pos : int; len : int }

let resize_mappings (resize_data : resize_data) mappings =
  if String.equal mappings "" || resize_data.i = 0 then mappings
  else begin
    let src =
      { Vlq64.string = mappings; pos = 0; len = String.length mappings }
    in
    let buf = Buffer.create (String.length mappings) in
    let col = ref 0 in
    let new_col_acc = ref 0 in
    let idx = ref 0 in
    let shift = ref 0 in
    (* A segment's fields after the generated column (source index, original
       line/column, name index) are encoded as deltas relative to the previous
       segment, and accumulate across the whole mappings string. Dropping a
       segment therefore cannot simply discard those deltas: doing so would
       shift the source position of every surviving segment after it. Carry the
       deltas of dropped segments in these accumulators and fold each into the
       next survivor that emits the corresponding field. A field is reset only
       when it is emitted, so its chain stays intact across intervening
       survivors that omit it (e.g. a bare generated-column segment). *)
    let pending_source = ref 0 in
    let pending_line = ref 0 in
    let pending_col = ref 0 in
    let pending_name = ref 0 in
    let emitted = ref false in
    (* The generated-column field is already decoded; read the remaining fields
       of the current segment (0 for a bare column, 3, or 4 with a name), up to
       the next separator or the end. *)
    let read_tail () =
      let rec loop acc =
        if src.pos < src.len && Vlq64.in_alphabet src.string.[src.pos] then
          loop (Vlq64.decode src :: acc)
        else List.rev acc
      in
      loop []
    in
    let accumulate tail =
      match tail with
      | source :: line :: column :: rest -> (
          pending_source := !pending_source + source;
          pending_line := !pending_line + line;
          pending_col := !pending_col + column;
          match rest with
          | name :: _ -> pending_name := !pending_name + name
          | [] -> ())
      | _ -> ()
    in
    let emit_tail tail =
      match tail with
      | [] -> ()
      | source :: line :: column :: rest -> (
          Vlq64.encode buf (source + !pending_source);
          Vlq64.encode buf (line + !pending_line);
          Vlq64.encode buf (column + !pending_col);
          pending_source := 0;
          pending_line := 0;
          pending_col := 0;
          match rest with
          | [] -> ()
          | name :: rest ->
              Vlq64.encode buf (name + !pending_name);
              pending_name := 0;
              List.iter ~f:(Vlq64.encode buf) rest)
      | fields -> List.iter ~f:(Vlq64.encode buf) fields
    in
    let rec segment () =
      if src.pos < src.len && Vlq64.in_alphabet src.string.[src.pos] then begin
        col := !col + Vlq64.decode src;
        let tail = read_tail () in
        while !idx < resize_data.i && !col >= resize_data.pos.(!idx) do
          shift := !shift + resize_data.delta.(!idx);
          idx := !idx + 1
        done;
        let new_col = !col + !shift in
        if new_col < 0 then accumulate tail
        else begin
          if !emitted then Buffer.add_char buf ',';
          emitted := true;
          Vlq64.encode buf (new_col - !new_col_acc);
          new_col_acc := new_col;
          emit_tail tail
        end
      end;
      if src.pos < src.len && Char.equal src.string.[src.pos] ',' then begin
        src.pos <- src.pos + 1;
        segment ()
      end
    in
    segment ();
    Buffer.contents buf
  end

let resize resize_data (sm : Standard.t) =
  let mappings = Mappings.to_string sm.mappings in
  let mappings = resize_mappings resize_data mappings in
  { sm with mappings = Mappings.of_string_unsafe mappings }

let is_empty { Standard.mappings; _ } = Mappings.is_empty mappings

let concatenate l =
  {
    Index.version = 3;
    file = None;
    sections =
      List.map
        ~f:(fun (ofs, map) ->
          { Index.offset = { Offset.gen_line = 0; gen_column = ofs }; map })
        l;
  }
