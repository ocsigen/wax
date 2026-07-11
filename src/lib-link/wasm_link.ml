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

module IntHashtbl = Hashtbl.Make (struct
  type t = int

  let equal (x : int) y = x = y
  let hash (x : int) = x
end)

module StringHashtbl = Hashtbl.Make (struct
  type t = string

  let equal = String.equal
  let hash = Hashtbl.hash
end)

open Wax_wasm.Ast.Binary
module Uint64 = Wax_utils.Uint64
module Ast = Wax_utils.Ast

let dummy_loc = { Ast.loc_start = Lexing.dummy_pos; loc_end = Lexing.dummy_pos }

(* Linker diagnostics name three kinds of user-facing string: a file, an
   export, and an import (a "module"/"name" pair). Render each as a quoted
   string atom so every message displays them the same way (and colours them
   alike when colour is on). *)
let str s =
  Wax_utils.Message.styled Wax_utils.Colors.String (Printf.sprintf "%S" s)

let import_atom module_ name =
  Wax_utils.Message.(str module_ ++ text "/" ++ str name)

type link_subtyping_info = {
  wasm_info : Wax_wasm.Types.subtyping_info;
  types_map : (int, Wax_wasm.Types.ref_index) Hashtbl.t;
}

let get_id types_map idx =
  match Hashtbl.find types_map idx with
  | Wax_wasm.Types.Def id -> id
  | Rec _ -> assert false

let rec to_internal_heaptype types_map (ht : heaptype) :
    Wax_wasm.Types.Internal.heaptype =
  match ht with
  | Func -> Func
  | NoFunc -> NoFunc
  | Extern -> Extern
  | NoExtern -> NoExtern
  | Exn -> Exn
  | NoExn -> NoExn
  | Cont -> Cont
  | NoCont -> NoCont
  | Any -> Any
  | Eq -> Eq
  | I31 -> I31
  | Struct -> Struct
  | Array -> Array
  | None_ -> None_
  | Type idx -> Type (get_id types_map idx)
  | Exact idx -> Exact (get_id types_map idx)

and to_internal_reftype types_map (rt : reftype) :
    Wax_wasm.Types.Internal.reftype =
  { nullable = rt.nullable; typ = to_internal_heaptype types_map rt.typ }

and to_internal_valtype types_map (vt : valtype) :
    Wax_wasm.Types.Internal.valtype =
  match vt with
  | I32 -> I32
  | I64 -> I64
  | F32 -> F32
  | F64 -> F64
  | V128 -> V128
  | Ref rt -> Ref (to_internal_reftype types_map rt)

let reftype_eq (info : link_subtyping_info) t1 t2 =
  let rt1 = to_internal_reftype info.types_map t1 in
  let rt2 = to_internal_reftype info.types_map t2 in
  Wax_wasm.Types.reftype_equal rt1 rt2

let valtype_eq (info : link_subtyping_info) t1 t2 =
  let vt1 = to_internal_valtype info.types_map t1 in
  let vt2 = to_internal_valtype info.types_map t2 in
  Wax_wasm.Types.valtype_equal vt1 vt2

let rec to_normalized_heaptype types_map (ht : heaptype) :
    Wax_wasm.Types.Normalized.heaptype =
  match ht with
  | Func -> Func
  | NoFunc -> NoFunc
  | Extern -> Extern
  | NoExtern -> NoExtern
  | Exn -> Exn
  | NoExn -> NoExn
  | Cont -> Cont
  | NoCont -> NoCont
  | Any -> Any
  | Eq -> Eq
  | I31 -> I31
  | Struct -> Struct
  | Array -> Array
  | None_ -> None_
  | Type idx -> Type (Hashtbl.find types_map idx)
  | Exact idx -> Exact (Hashtbl.find types_map idx)

and to_normalized_reftype types_map (rt : reftype) :
    Wax_wasm.Types.Normalized.reftype =
  { nullable = rt.nullable; typ = to_normalized_heaptype types_map rt.typ }

and to_normalized_valtype types_map (vt : valtype) :
    Wax_wasm.Types.Normalized.valtype =
  match vt with
  | I32 -> I32
  | I64 -> I64
  | F32 -> F32
  | F64 -> F64
  | V128 -> V128
  | Ref rt -> Ref (to_normalized_reftype types_map rt)

let to_normalized_packedtype (pt : packedtype) :
    Wax_wasm.Types.Normalized.packedtype =
  match pt with I8 -> I8 | I16 -> I16

let to_normalized_storagetype types_map (st : storagetype) :
    Wax_wasm.Types.Normalized.storagetype =
  match st with
  | Value vt -> Value (to_normalized_valtype types_map vt)
  | Packed pt -> Packed (to_normalized_packedtype pt)

let to_normalized_fieldtype types_map (ft : fieldtype) :
    Wax_wasm.Types.Normalized.fieldtype =
  { mut = ft.mut; typ = to_normalized_storagetype types_map ft.typ }

let to_normalized_comptype types_map (ct : comptype) :
    Wax_wasm.Types.Normalized.comptype =
  match ct with
  | Func { params; results } ->
      Func
        {
          params = Array.map (to_normalized_valtype types_map) params;
          results = Array.map (to_normalized_valtype types_map) results;
        }
  | Struct fields ->
      Struct (Array.map (to_normalized_fieldtype types_map) fields)
  | Array field -> Array (to_normalized_fieldtype types_map field)
  | Cont idx -> Cont (Hashtbl.find types_map idx)

let to_normalized_subtype types_map { final; supertype; typ; _ } =
  let supertype = Option.map (Hashtbl.find types_map) supertype in
  {
    Wax_wasm.Types.Normalized.final;
    supertype;
    typ = to_normalized_comptype types_map typ;
    descriptor = None;
    describes = None;
  }

let map_heaptype f (ht : heaptype) : heaptype =
  match ht with
  | Type idx -> Type (f idx)
  | Exact idx -> Exact (f idx)
  | other -> other

let map_reftype f (rt : reftype) : reftype =
  { rt with typ = map_heaptype f rt.typ }

let map_valtype f (vt : valtype) : valtype =
  match vt with Ref rt -> Ref (map_reftype f rt) | other -> other

let map_storagetype f (st : storagetype) : storagetype =
  match st with Value vt -> Value (map_valtype f vt) | Packed pt -> Packed pt

let map_fieldtype f { mut; typ } = { mut; typ = map_storagetype f typ }

let map_comptype f (ct : comptype) : comptype =
  match ct with
  | Func { params; results } ->
      Func
        {
          params = Array.map (map_valtype f) params;
          results = Array.map (map_valtype f) results;
        }
  | Struct fields -> Struct (Array.map (map_fieldtype f) fields)
  | Array field -> Array (map_fieldtype f field)
  | Cont idx -> Cont (f idx)

let map_subtype f (st : subtype) : subtype =
  { st with supertype = Option.map f st.supertype; typ = map_comptype f st.typ }

let map_rectype f (group : rectype) : rectype = Array.map (map_subtype f) group

let rec output_uint ch i =
  if i < 128 then output_byte ch i
  else (
    output_byte ch (128 + (i land 127));
    output_uint ch (i lsr 7))

module Write = struct
  open Wax_wasm.Wasm_output.Encoder

  let uint = uint
  let name = name

  let nameassoc ch idx nm =
    uint ch idx;
    name ch nm

  let namemap ch l = vec' (fun ch (idx, name) -> nameassoc ch idx name) ch l
end

type 'a exportable_info = {
  mutable func : 'a;
  mutable table : 'a;
  mutable mem : 'a;
  mutable global : 'a;
  mutable tag : 'a;
}

let iter_exportable_info (f : exportable -> 'a -> unit)
    { func; table; mem; global; tag } =
  f Func func;
  f Table table;
  f Memory mem;
  f Global global;
  f Tag tag

let map_exportable_info (f : exportable -> 'a -> 'b)
    { func; table; mem; global; tag } =
  {
    func = f Func func;
    table = f Table table;
    mem = f Memory mem;
    global = f Global global;
    tag = f Tag tag;
  }

let init_exportable_info f =
  { func = f (); table = f (); mem = f (); global = f (); tag = f () }

let make_exportable_info v = init_exportable_info (fun _ -> v)

let get_exportable_info info (kind : exportable) =
  match kind with
  | Func -> info.func
  | Table -> info.table
  | Memory -> info.mem
  | Global -> info.global
  | Tag -> info.tag

let set_exportable_info info (kind : exportable) v =
  match kind with
  | Func -> info.func <- v
  | Table -> info.table <- v
  | Memory -> info.mem <- v
  | Global -> info.global <- v
  | Tag -> info.tag <- v

module Read = struct
  type ch = Wax_wasm.Wasm_parser.ch
  type index = Wax_wasm.Wasm_parser.index

  let pos_in = Wax_wasm.Wasm_parser.pos_in
  let seek_in = Wax_wasm.Wasm_parser.seek_in
  let uint ch = Wax_wasm.Wasm_parser.uint ch

  let repeat' n f ch =
    for _ = 1 to n do
      f ch
    done

  let name = Wax_wasm.Wasm_parser.name

  type t = { id : int; ch : ch; index : index }

  (* [id] is the module's position among the linked inputs; it indexes the
     per-call [type_mappings] array, so the caller passes the input index. *)
  let open_in id f buf =
    Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
      ~palette:Wax_utils.Colors.wat_theme ~source:(Some buf) (fun d ->
        let ch = Wax_wasm.Wasm_parser.make_ch d ~filename:f buf 0 in
        Wax_wasm.Wasm_parser.check_header ch;
        { id; ch; index = Wax_wasm.Wasm_parser.index ch })

  type types = {
    types_store : Wax_wasm.Types.t;
    types_map : (int, Wax_wasm.Types.ref_index) Hashtbl.t;
    type_mappings : int array array;
    mutable kept_rectypes : (int array * subtype array) list;
  }

  let get_type_mapping types st = types.type_mappings.(st.id)
  let set_type_mapping types st map = types.type_mappings.(st.id) <- map

  let create_types n =
    {
      types_store = Wax_wasm.Types.create ();
      types_map = Hashtbl.create 16;
      type_mappings = Array.make n [||];
      kept_rectypes = [];
    }

  let find_section contents n =
    Wax_wasm.Wasm_parser.find_section contents.ch contents.index n

  let focus_on_custom_section contents section =
    let ch, index =
      Wax_wasm.Wasm_parser.focus_on_custom_section contents.ch contents.index
        section
    in
    { contents with ch; index }

  let focus_on_custom_section_payload contents name =
    match Wax_wasm.Wasm_parser.get_custom_section contents.index name with
    | None -> { contents with ch = { contents.ch with pos = 0; limit = 0 } }
    | Some { pos; size; _ } ->
        let ch = { contents.ch with pos; limit = pos + size } in
        ignore (Wax_wasm.Wasm_parser.name ch);
        { contents with ch }

  let add_rectype types type_mapping ty =
    let group_start_idx = Hashtbl.length types.types_map in
    let count = Array.length ty in
    for i = 0 to count - 1 do
      Hashtbl.replace types.types_map (group_start_idx + i)
        (Wax_wasm.Types.Rec i)
    done;
    let normalized = Array.map (to_normalized_subtype types.types_map) ty in
    let first_id = Wax_wasm.Types.add_rectype types.types_store normalized in
    let first_int = Wax_wasm.Types.Id.to_int_for_tests_only first_id in
    if first_int < group_start_idx then (
      (* Deduplicated! *)
      for i = 0 to count - 1 do
        Hashtbl.remove types.types_map (group_start_idx + i)
      done;
      first_int)
    else (
      (* New type group *)
      for i = 0 to count - 1 do
        Hashtbl.replace types.types_map (group_start_idx + i)
          (Wax_wasm.Types.Def (Wax_wasm.Types.Id.add first_id i))
      done;
      types.kept_rectypes <- (type_mapping, ty) :: types.kept_rectypes;
      first_int)

  let translate_heaptype type_mapping (ht : heaptype) : heaptype =
    match ht with
    | Type idx -> Type type_mapping.(idx)
    | Exact idx -> Exact type_mapping.(idx)
    | other -> other

  let translate_reftype type_mapping (rt : reftype) : reftype =
    { rt with typ = translate_heaptype type_mapping rt.typ }

  let translate_valtype type_mapping (vt : valtype) : valtype =
    match vt with
    | Ref rt -> Ref (translate_reftype type_mapping rt)
    | other -> other

  let translate_tabletype type_mapping (tt : tabletype) : tabletype =
    { tt with reftype = translate_reftype type_mapping tt.reftype }

  let translate_globaltype type_mapping (gt : globaltype) : globaltype =
    { gt with typ = translate_valtype type_mapping gt.typ }

  let translate_importdesc type_mapping (desc : importdesc) : importdesc =
    match desc with
    | Func { exact; typ } -> Func { exact; typ = type_mapping.(typ) }
    | Table tt -> Table (translate_tabletype type_mapping tt)
    | Memory lim -> Memory lim
    | Global gt -> Global (translate_globaltype type_mapping gt)
    | Tag idx -> Tag type_mapping.(idx)

  let tabletype st types ch =
    let type_mapping = get_type_mapping types st in
    translate_tabletype type_mapping (Wax_wasm.Wasm_parser.tabletype ch)

  let globaltype st types ch =
    let type_mapping = get_type_mapping types st in
    translate_globaltype type_mapping (Wax_wasm.Wasm_parser.globaltype ch)

  let type_section st types ch =
    let groups = Wax_wasm.Wasm_parser.type_section ch in
    let n = Array.fold_left (fun acc g -> acc + Array.length g) 0 groups in
    let type_mapping = Array.make n 0 in
    set_type_mapping types st type_mapping;
    let pos = ref 0 in
    Array.iter
      (fun ty ->
        let count = Array.length ty in
        let pos' = add_rectype types type_mapping ty in
        for i = 0 to count - 1 do
          type_mapping.(!pos + i) <- pos' + i
        done;
        pos := !pos + count)
      groups

  type interface = {
    imports : import array exportable_info;
    exports : (string * int) list exportable_info;
  }

  let type_section types contents =
    if find_section contents 1 then type_section contents types contents.ch

  let interface types contents =
    let imports =
      if find_section contents 2 then (
        let type_mapping = get_type_mapping types contents in
        let raw_imports =
          Wax_wasm.Ast_utils.flatten_binary_imports
            (Wax_wasm.Wasm_parser.import_section contents.ch)
        in
        let tbl = make_exportable_info [] in
        List.iter
          (fun (imp : import) ->
            let desc = translate_importdesc type_mapping imp.desc in
            let kind : exportable =
              match desc with
              | Func _ -> Func
              | Table _ -> Table
              | Memory _ -> Memory
              | Global _ -> Global
              | Tag _ -> Tag
            in
            set_exportable_info tbl kind
              ({ imp with desc } :: get_exportable_info tbl kind))
          raw_imports;
        map_exportable_info (fun _ l -> Array.of_list (List.rev l)) tbl)
      else make_exportable_info [||]
    in
    let exports =
      let tbl = make_exportable_info [] in
      (if find_section contents 7 then
         let raw_exports = Wax_wasm.Wasm_parser.export_section contents.ch in
         Array.iter
           (fun (exp : export) ->
             set_exportable_info tbl exp.kind
               ((exp.name, exp.index) :: get_exportable_info tbl exp.kind))
           raw_exports);
      tbl
    in
    { imports; exports }

  let functions types contents =
    if find_section contents 3 then
      let raw_funcs = Wax_wasm.Wasm_parser.function_section contents.ch in
      let type_mapping = get_type_mapping types contents in
      Array.map (fun idx -> type_mapping.(idx)) raw_funcs
    else [||]

  let memories contents =
    if find_section contents 5 then
      Wax_wasm.Wasm_parser.memory_section contents.ch
    else [||]

  let tags types contents =
    if find_section contents 13 then
      let raw_tags = Wax_wasm.Wasm_parser.tag_section contents.ch in
      let type_mapping = get_type_mapping types contents in
      Array.map (fun idx -> type_mapping.(idx)) raw_tags
    else [||]

  let data_count contents =
    if find_section contents 12 then
      Wax_wasm.Wasm_parser.datacount_section contents.ch
    else if find_section contents 11 then
      Wax_wasm.Wasm_parser.datacount_section contents.ch
    else 0

  let start contents =
    if find_section contents 8 then
      Some (Wax_wasm.Wasm_parser.start_section contents.ch)
    else None

  let namemap contents = Wax_wasm.Wasm_parser.namemap contents.ch
end

let read_branch_hints (contents : Read.t) =
  if contents.ch.limit > 0 then
    Array.to_list (Wax_wasm.Wasm_parser.branch_hint_section contents.ch)
  else []

module Scan = struct
  let debug = false

  type maps = {
    typ : int array;
    func : int array;
    table : int array;
    mem : int array;
    global : int array;
    elem : int array;
    data : int array;
    tag : int array;
  }

  let default_maps =
    {
      typ = [||];
      func = [||];
      table = [||];
      mem = [||];
      global = [||];
      elem = [||];
      data = [||];
      tag = [||];
    }

  type resize_data = Js_source_map.resize_data = {
    mutable i : int;
    mutable pos : int array;
    mutable delta : int array;
  }

  let push_resize resize_data pos delta =
    let p = resize_data.pos in
    let i = resize_data.i in
    let p =
      if i = Array.length p then (
        let p = Array.make (2 * i) 0 in
        let d = Array.make (2 * i) 0 in
        Array.blit resize_data.pos 0 p 0 i;
        Array.blit resize_data.delta 0 d 0 i;
        resize_data.pos <- p;
        resize_data.delta <- d;
        p)
      else p
    in
    p.(i) <- pos;
    resize_data.delta.(i) <- delta;
    resize_data.i <- i + 1

  let create_resize_data () =
    { i = 0; pos = Array.make 1024 0; delta = Array.make 1024 0 }

  let clear_resize_data resize_data = resize_data.i <- 0

  type position_data = { mutable i : int; mutable pos : int array }

  let create_position_data () = { i = 0; pos = Array.make 100 0 }
  let clear_position_data position_data = position_data.i <- 0

  let push_position position_data pos =
    let p = position_data.pos in
    let i = position_data.i in
    let p =
      if i = Array.length p then (
        let p = Array.make (2 * i) 0 in
        Array.blit position_data.pos 0 p 0 i;
        position_data.pos <- p;
        p)
      else p
    in
    p.(i) <- pos;
    position_data.i <- i + 1

  let scanner ?(mark_instructions = false) report mark maps buf code =
    let rec output_uint buf i =
      if i < 128 then Buffer.add_char buf (Char.chr i)
      else (
        Buffer.add_char buf (Char.chr (128 + (i land 127)));
        output_uint buf (i lsr 7))
    in
    let rec output_sint buf i =
      if i >= -64 && i < 64 then Buffer.add_char buf (Char.chr (i land 127))
      else (
        Buffer.add_char buf (Char.chr (128 + (i land 127)));
        output_sint buf (i asr 7))
    in
    let start = ref 0 in
    let in_func = ref false in
    let get pos = Char.code (String.get code pos) in
    let rec int pos = if get pos >= 128 then int (pos + 1) else pos + 1 in
    let rec uint32 pos =
      let i = get pos in
      if i < 128 then (pos + 1, i)
      else
        let pos, i' = pos + 1 |> uint32 in
        (pos, (i' lsl 7) + (i land 0x7f))
    in
    let rec sint32 pos =
      let i = get pos in
      if i < 64 then (pos + 1, i)
      else if i < 128 then (pos + 1, i - 128)
      else
        let pos, i' = pos + 1 |> sint32 in
        (pos, i - 128 + (i' lsl 7))
    in
    let rec repeat n f pos = if n = 0 then pos else repeat (n - 1) f (f pos) in
    let vector f pos =
      let pos, i =
        let i = get pos in
        if i < 128 then (pos + 1, i) else uint32 pos
      in
      repeat i f pos
    in
    let name pos =
      let pos', i =
        let i = get pos in
        if i < 128 then (pos + 1, i) else uint32 pos
      in
      pos' + i
    in
    let flush' pos pos' =
      if !start < pos then Buffer.add_substring buf code !start (pos - !start);
      start := pos'
    in
    let flush pos = flush' pos pos in
    let rewrite map pos =
      let pos', idx =
        let i = get pos in
        if i < 128 then (pos + 1, i)
        else
          let i' = get (pos + 1) in
          if i' < 128 then (pos + 2, (i' lsl 7) + (i land 0x7f)) else uint32 pos
      in
      let idx' = map idx in
      if idx <> idx' then (
        flush' pos pos';
        let p = Buffer.length buf in
        output_uint buf idx';
        let p' = Buffer.length buf in
        let dp = p' - p in
        let dpos = pos' - pos in
        if dp <> dpos then report pos' (dp - dpos));
      pos'
    in
    let rewrite_signed map pos =
      let pos', idx =
        let i = get pos in
        if i < 64 then (pos + 1, i)
        else if i < 128 then (pos + 1, i - 128)
        else sint32 pos
      in
      let idx' = map idx in
      if idx <> idx' then (
        flush' pos pos';
        let p = Buffer.length buf in
        output_sint buf idx';
        let p' = Buffer.length buf in
        let dp = p' - p in
        let dpos = pos' - pos in
        if dp <> dpos then report pos (dp - dpos));
      pos'
    in
    let typ_map idx = maps.typ.(idx) in
    let typeidx pos = rewrite typ_map pos in
    let signed_typeidx pos = rewrite_signed typ_map pos in
    let func_map idx = maps.func.(idx) in
    let funcidx pos = rewrite func_map pos in
    let table_map idx = maps.table.(idx) in
    let tableidx pos = rewrite table_map pos in
    let mem_map idx = maps.mem.(idx) in
    let memidx pos = rewrite mem_map pos in
    let global_map idx = maps.global.(idx) in
    let globalidx pos = rewrite global_map pos in
    let elem_map idx = maps.elem.(idx) in
    let elemidx pos = rewrite elem_map pos in
    let data_map idx = maps.data.(idx) in
    let dataidx pos = rewrite data_map pos in
    let tag_map idx = maps.tag.(idx) in
    let tagidx pos = rewrite tag_map pos in
    let labelidx = int in
    let localidx = int in
    let laneidx pos = pos + 1 in
    let heaptype pos =
      let c = get pos in
      if c >= 64 && c < 128 then (* absheaptype *) pos + 1
      else signed_typeidx pos
    in
    let absheaptype pos =
      match get pos with
      | 0X73 (* nofunc *)
      | 0x72 (* noextern *)
      | 0x71 (* none *)
      | 0x70 (* func *)
      | 0x6F (* extern *)
      | 0x6E (* any *)
      | 0x6D (* eq *)
      | 0x6C (* i31 *)
      | 0x6B (* struct *)
      | 0x6A (* array *) ->
          pos + 1
      | c -> failwith (Printf.sprintf "Bad heap type 0x%02X@." c)
    in
    let reftype pos =
      match get pos with
      | 0x63 | 0x64 -> pos + 1 |> heaptype
      | _ -> pos |> absheaptype
    in
    let valtype pos =
      let c = get pos in
      match c with
      | 0x63 (* ref null ht *) | 0x64 (* ref ht *) -> pos + 1 |> heaptype
      | _ -> pos + 1
    in
    let blocktype pos =
      let c = get pos in
      if c >= 64 && c < 128 then pos |> valtype else pos |> signed_typeidx
    in
    let memarg pos =
      let pos', c = uint32 pos in
      if c < 64 then (
        if mem_map 0 <> 0 then (
          flush' pos pos';
          let p = Buffer.length buf in
          output_uint buf (c + 64);
          output_uint buf (mem_map 0);
          let p' = Buffer.length buf in
          let dp = p' - p in
          let dpos = pos' - pos in
          if dp <> dpos then report pos (dp - dpos));
        pos' |> int)
      else pos' |> memidx |> int
    in
    let rec instructions pos =
      if debug then Format.eprintf "0x%02X (@%d)@." (get pos) pos;
      if mark_instructions && !in_func then mark pos;
      match get pos with
      (* Control instruction *)
      | 0x00 (* unreachable *) | 0x01 (* nop *) | 0x0F (* return *) ->
          pos + 1 |> instructions
      | 0x02 (* block *) | 0x03 (* loop *) ->
          pos + 1 |> blocktype |> instructions |> block_end |> instructions
      | 0x04 (* if *) ->
          pos + 1 |> blocktype |> instructions |> opt_else |> instructions
      | 0x0C (* br *)
      | 0x0D (* br_if *)
      | 0xD5 (* br_on_null *)
      | 0xD6 (* br_on_non_null *) ->
          pos + 1 |> labelidx |> instructions
      | 0x0E (* br_table *) ->
          pos + 1 |> vector labelidx |> labelidx |> instructions
      | 0x10 (* call *) | 0x12 (* return_call *) ->
          pos + 1 |> funcidx |> instructions
      | 0x11 (* call_indirect *) | 0x13 (* return_call_indirect *) ->
          pos + 1 |> typeidx |> tableidx |> instructions
      | 0x14 (* call_ref *) | 0x15 (* return_call_ref *) ->
          pos + 1 |> typeidx |> instructions
      (* Exceptions *)
      | 0x06 (* try *) -> pos + 1 |> blocktype |> instructions |> opt_catch
      | 0x08 (* throw *) -> pos + 1 |> tagidx |> instructions
      | 0x09 (* rethrow *) -> pos + 1 |> int |> instructions
      | 0x0A (* throw_ref *) -> pos + 1 |> instructions
      (* Parametric instructions *)
      | 0x1A (* drop *) | 0x1B (* select *) -> pos + 1 |> instructions
      | 0x1C (* select *) -> pos + 1 |> vector valtype |> instructions
      | 0x1F (* try_table *) ->
          pos + 1 |> blocktype |> vector catch |> instructions |> block_end
          |> instructions
      (* Variable instructions *)
      | 0x20 (* local.get *) | 0x21 (* local.set *) | 0x22 (* local.tee *) ->
          pos + 1 |> localidx |> instructions
      | 0x23 (* global.get *) | 0x24 (* global.set *) ->
          pos + 1 |> globalidx |> instructions
      (* Table instructions *)
      | 0x25 (* table.get *) | 0x26 (* table.set *) ->
          pos + 1 |> tableidx |> instructions
      (* Memory instructions *)
      | 0x28 | 0x29 | 0x2A | 0x2B | 0x2C | 0x2D | 0x2E | 0x2F | 0x30 | 0x31
      | 0x32 | 0x33 | 0x34 | 0x35 (* load *)
      | 0x36 | 0x37 | 0x38 | 0x39 | 0x3A | 0x3B | 0x3C | 0x3D | 0x3E (* store *)
        ->
          pos + 1 |> memarg |> instructions
      | 0x3F | 0x40 -> pos + 1 |> memidx |> instructions
      (* Numeric instructions *)
      | 0x41 (* i32.const *) | 0x42 (* i64.const *) ->
          pos + 1 |> int |> instructions
      | 0x43 (* f32.const *) -> pos + 5 |> instructions
      | 0x44 (* f64.const *) -> pos + 9 |> instructions
      | 0x45 | 0x46 | 0x47 | 0x48 | 0x49 | 0x4A | 0x4B | 0x4C | 0x4D | 0x4E
      | 0x4F | 0x50 | 0x51 | 0x52 | 0x53 | 0x54 | 0x55 | 0x56 | 0x57 | 0x58
      | 0x59 | 0x5A | 0x5B | 0x5C | 0x5D | 0x5E | 0x5F | 0x60 | 0x61 | 0x62
      | 0x63 | 0x64 | 0x65 | 0x66 | 0x67 | 0x68 | 0x69 | 0x6A | 0x6B | 0x6C
      | 0x6D | 0x6E | 0x6F | 0x70 | 0x71 | 0x72 | 0x73 | 0x74 | 0x75 | 0x76
      | 0x77 | 0x78 | 0x79 | 0x7A | 0x7B | 0x7C | 0x7D | 0x7E | 0x7F | 0x80
      | 0x81 | 0x82 | 0x83 | 0x84 | 0x85 | 0x86 | 0x87 | 0x88 | 0x89 | 0x8A
      | 0x8B | 0x8C | 0x8D | 0x8E | 0x8F | 0x90 | 0x91 | 0x92 | 0x93 | 0x94
      | 0x95 | 0x96 | 0x97 | 0x98 | 0x99 | 0x9A | 0x9B | 0x9C | 0x9D | 0x9E
      | 0x9F | 0xA0 | 0xA1 | 0xA2 | 0xA3 | 0xA4 | 0xA5 | 0xA6 | 0xA7 | 0xA8
      | 0xA9 | 0xAA | 0xAB | 0xAC | 0xAD | 0xAE | 0xAF | 0xB0 | 0xB1 | 0xB2
      | 0xB3 | 0xB4 | 0xB5 | 0xB6 | 0xB7 | 0xB8 | 0xB9 | 0xBA | 0xBB | 0xBC
      | 0xBD | 0xBE | 0xBF | 0xC0 | 0xC1 | 0xC2 | 0xC3 | 0xC4 ->
          pos + 1 |> instructions
      (* Reference instructions *)
      | 0xD0 (* ref.null *) -> pos + 1 |> heaptype |> instructions
      | 0xD1 (* ref.is_null *) | 0xD3 (* ref.eq *) | 0xD4 (* ref.as_non_null *)
        ->
          pos + 1 |> instructions
      | 0xD2 (* ref.func *) -> pos + 1 |> funcidx |> instructions
      | 0xE0 (* cont.new *) -> pos + 1 |> typeidx |> instructions
      | 0xE1 (* cont.bind *) -> pos + 1 |> typeidx |> typeidx |> instructions
      | 0xE2 (* suspend *) -> pos + 1 |> tagidx |> instructions
      | 0xE3 (* resume *) ->
          pos + 1 |> typeidx |> vector on_clause |> instructions
      | 0xE4 (* resume_throw *) ->
          pos + 1 |> typeidx |> tagidx |> vector on_clause |> instructions
      | 0xE5 (* resume_throw_ref *) ->
          pos + 1 |> typeidx |> vector on_clause |> instructions
      | 0xE6 (* switch *) -> pos + 1 |> typeidx |> tagidx |> instructions
      | 0xFB -> pos + 1 |> gc_instruction
      | 0xFC -> (
          if debug then Format.eprintf "  %d@." (get (pos + 1));
          match get (pos + 1) with
          | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 (* xx.trunc_sat_xxx_x *)
          | 19 (* add128 *)
          | 20 (* sub128 *)
          | 21 | 22 (* mul_wide *) ->
              pos + 2 |> instructions
          | 8 (* memory.init *) -> pos + 2 |> dataidx |> memidx |> instructions
          | 9 (* data.drop *) -> pos + 2 |> dataidx |> instructions
          | 10 (* memory.copy *) -> pos + 2 |> memidx |> memidx |> instructions
          | 11 (* memory.fill *) -> pos + 2 |> memidx |> instructions
          | 12 (* table.init *) ->
              pos + 2 |> elemidx |> tableidx |> instructions
          | 13 (* elem.drop *) -> pos + 2 |> elemidx |> instructions
          | 14 (* table.copy *) ->
              pos + 2 |> tableidx |> tableidx |> instructions
          | 15 (* table.grow *) | 16 (* table.size *) | 17 (* table.fill *) ->
              pos + 2 |> tableidx |> instructions
          | c -> failwith (Printf.sprintf "Bad instruction 0xFC 0x%02X" c))
      | 0xFD -> pos + 1 |> vector_instruction
      | 0xFE -> pos + 1 |> atomic_instruction
      | _ -> pos
    and gc_instruction pos =
      if debug then Format.eprintf "  %d@." (get pos);
      match get pos with
      | 0 (* struct.new *)
      | 1 (* struct.new_default *)
      | 6 (* array.new *)
      | 7 (* array.new_default *)
      | 11 (* array.get *)
      | 12 (* array.get_s *)
      | 13 (* array.get_u *)
      | 14 (* array.set *)
      | 16 (* array.fill *)
      | 32 (* struct.new_desc *)
      | 33 (* struct.new_default_desc *)
      | 34 (* ref.get_desc *) ->
          pos + 1 |> typeidx |> instructions
      | 2 (* struct.get *)
      | 3 (* struct.get_s *)
      | 4 (* struct.get_u *)
      | 5 (* struct.set *)
      | 8 (* array.new_fixed *) ->
          pos + 1 |> typeidx |> int |> instructions
      | 9 (* array.new_data *) | 18 (* array.init_data *) ->
          pos + 1 |> typeidx |> dataidx |> instructions
      | 10 (* array.new_elem *) | 19 (* array.init_elem *) ->
          pos + 1 |> typeidx |> elemidx |> instructions
      | 15 (* array.len *)
      | 26 (* any.convert_extern *)
      | 27 (* extern.convert_any *)
      | 28 (* ref.i31 *)
      | 29 (* i31.get_s *)
      | 30 (* i31.get_u *) ->
          pos + 1 |> instructions
      | 17 (* array.copy *) -> pos + 1 |> typeidx |> typeidx |> instructions
      | 20 | 21 (* ref_test *)
      | 22 | 23 (* ref.cast*)
      | 35 | 36 (* ref.cast_desc_eq *) ->
          pos + 1 |> heaptype |> instructions
      | 24 (* br_on_cast *)
      | 25 (* br_on_cast_fail *)
      | 37 (* br_on_cast_desc_eq *)
      | 38 (* br_on_cast_desc_eq_fail *) ->
          pos + 2 |> labelidx |> heaptype |> heaptype |> instructions
      | c -> failwith (Printf.sprintf "Bad instruction 0xFB 0x%02X" c)
    and vector_instruction pos =
      if debug then Format.eprintf "  %d@." (get pos);
      (* [uint32] already consumes the (LEB-encoded) SIMD sub-opcode, so each
         arm starts at the immediate — do not skip another byte. *)
      let pos, i = uint32 pos in
      match i with
      | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 92
      | 93 (* v128.load / store *) ->
          pos |> memarg |> instructions
      | 84 | 85 | 86 | 87 | 88 | 89 | 90 | 91 (* v128.load/store_lane *) ->
          pos |> memarg |> laneidx |> instructions
      | 12 (* v128.const *) | 13 (* v128.shuffle *) -> pos + 16 |> instructions
      | 21 | 22 | 23 | 24 | 25 | 26 | 27 | 28 | 29 | 30 | 31 | 32 | 33
      | 34 (* xx.extract/replace_lane *) ->
          pos |> laneidx |> instructions
      | ( 162 | 165 | 166 | 175 | 176 | 178 | 179 | 180 | 187 | 194 | 197 | 198
        | 207 | 208 | 210 | 211 | 212 | 226 | 238 ) as c ->
          failwith (Printf.sprintf "Bad instruction 0xFD 0x%02X" c)
      | c ->
          if c <= 275 then pos |> instructions
          else failwith (Printf.sprintf "Bad instruction 0xFD 0x%02X" c)
    and atomic_instruction pos =
      if debug then Format.eprintf "  %d@." (get pos);
      match get pos with
      | 0 (* memory.atomic.notify *)
      | 1 | 2 (* memory.atomic.waitxx *)
      | 16 | 17 | 18 | 19 | 20 | 21 | 22 (* xx.atomic.load *)
      | 23 | 24 | 25 | 26 | 27 | 28 | 29 (* xx.atomic.store *)
      | 30 | 31 | 32 | 33 | 34 | 35 | 36 (* xx.atomic.rmw.add *)
      | 37 | 38 | 39 | 40 | 41 | 42 | 43 (* xx.atomic.rmw.sub *)
      | 44 | 45 | 46 | 47 | 48 | 49 | 50 (* xx.atomic.rmw.and *)
      | 51 | 52 | 53 | 54 | 55 | 56 | 57 (* xx.atomic.rmw.or *)
      | 58 | 59 | 60 | 61 | 62 | 63 | 64 (* xx.atomic.rmw.xor *)
      | 65 | 66 | 67 | 68 | 69 | 70 | 71 (* xx.atomic.rmw.xchg *)
      | 72 | 73 | 74 | 75 | 76 | 77 | 78 (* xx.atomic.rmw.cmpxchg *) ->
          pos + 1 |> memarg |> instructions
      | 3 (* memory.fence *) ->
          let c = get (pos + 1) in
          assert (c = 0);
          pos + 2 |> instructions
      | c -> failwith (Printf.sprintf "Bad instruction 0xFE 0x%02X" c)
    and opt_else pos =
      if debug then Format.eprintf "0x%02X (@%d) else@." (get pos) pos;
      match get pos with
      | 0x05 (* else *) -> pos + 1 |> instructions |> block_end |> instructions
      | _ -> pos |> block_end |> instructions
    and opt_catch pos =
      if debug then Format.eprintf "0x%02X (@%d) catch@." (get pos) pos;
      match get pos with
      | 0x07 (* catch *) -> pos + 1 |> tagidx |> instructions |> opt_catch
      | 0x19 (* catch_all *) ->
          pos + 1 |> instructions |> block_end |> instructions
      | _ -> pos |> block_end |> instructions
    and catch pos =
      match get pos with
      | 0 (* catch *) | 1 (* catch_ref *) -> pos + 1 |> tagidx |> labelidx
      | 2 (* catch_all *) | 3 (* catch_all_ref *) -> pos + 1 |> labelidx
      | c -> failwith (Printf.sprintf "bad catch 0x%02x@." c)
    and on_clause pos =
      match get pos with
      | 0 (* on *) -> pos + 1 |> tagidx |> labelidx
      | 1 (* on .. switch *) -> pos + 1 |> tagidx
      | c -> failwith (Printf.sprintf "bad on clause 0x%02x@." c)
    and block_end pos =
      if debug then Format.eprintf "0x%02X (@%d) block end@." (get pos) pos;
      match get pos with
      | 0x0B -> pos + 1
      | c -> failwith (Printf.sprintf "Bad instruction 0x%02X" c)
    in
    let locals pos = pos |> int |> valtype in
    let expr pos = pos |> instructions |> block_end in
    let func pos =
      start := pos;
      in_func := true;
      let res = pos |> vector locals |> expr |> flush in
      in_func := false;
      res
    in
    let mut pos = pos + 1 in
    let limits pos =
      let c = get pos in
      assert (c < 8);
      if c land 1 = 0 then pos + 1 |> int else pos + 1 |> int |> int
    in
    let tabletype pos =
      mark pos;
      pos |> reftype |> limits
    in
    let table pos =
      match get pos with
      | 0x40 ->
          assert (get (pos + 1) = 0);
          pos + 2 |> tabletype |> expr
      | _ -> pos |> tabletype
    in
    let table_section ~count pos =
      start := pos;
      pos |> repeat count table |> flush
    in
    let globaltype pos =
      mark pos;
      pos |> valtype |> mut
    in
    let global pos = pos |> globaltype |> expr in
    let global_section ~count pos =
      start := pos;
      pos |> repeat count global |> flush
    in
    let elemkind pos =
      assert (get pos = 0);
      pos + 1
    in
    let elem pos =
      match get pos with
      | 0 -> pos + 1 |> expr |> vector funcidx
      | 1 -> pos + 1 |> elemkind |> vector funcidx
      | 2 -> pos + 1 |> tableidx |> expr |> elemkind |> vector funcidx
      | 3 -> pos + 1 |> elemkind |> vector funcidx
      | 4 -> pos + 1 |> expr |> vector expr
      | 5 -> pos + 1 |> reftype |> vector expr
      | 6 -> pos + 1 |> tableidx |> expr |> reftype |> vector expr
      | 7 -> pos + 1 |> reftype |> vector expr
      | c -> failwith (Printf.sprintf "Bad element 0x%02X" c)
    in
    let bytes pos =
      let pos, len = uint32 pos in
      pos + len
    in
    let data pos =
      match get pos with
      | 0 -> pos + 1 |> expr |> bytes
      | 1 -> pos + 1 |> bytes
      | 2 -> pos + 1 |> memidx |> expr |> bytes
      | c -> failwith (Printf.sprintf "Bad data segment 0x%02X" c)
    in
    let elem_section ~count pos =
      start := pos;
      !start |> repeat count elem |> flush
    in
    let data_section ~count pos =
      start := pos;
      !start |> repeat count data |> flush
    in
    let local_nameassoc pos = pos |> localidx |> name in
    let local_namemap pos =
      start := pos;
      pos |> vector local_nameassoc |> flush
    in
    ( table_section,
      global_section,
      elem_section,
      data_section,
      func,
      local_namemap )

  let table_section positions maps buf s =
    let table_section, _, _, _, _, _ =
      scanner
        (fun _ _ -> ())
        (fun pos -> push_position positions pos)
        maps buf s
    in
    table_section

  let global_section positions maps buf s =
    let _, global_section, _, _, _, _ =
      scanner
        (fun _ _ -> ())
        (fun pos -> push_position positions pos)
        maps buf s
    in
    global_section

  let elem_section maps buf s =
    let _, _, elem_section, _, _, _ =
      scanner (fun _ _ -> ()) (fun _ -> ()) maps buf s
    in
    elem_section

  let data_section maps buf s =
    let _, _, _, data_section, _, _ =
      scanner (fun _ _ -> ()) (fun _ -> ()) maps buf s
    in
    data_section

  let func resize_data maps buf s =
    let _, _, _, _, func, _ =
      scanner
        (fun pos delta -> push_resize resize_data pos delta)
        (fun _ -> ())
        maps buf s
    in
    func

  let local_namemap buf s =
    let _, _, _, _, _, local_namemap =
      scanner (fun _ _ -> ()) (fun _ -> ()) default_maps buf s
    in
    local_namemap
end

let interface types contents =
  Read.type_section types contents;
  Read.interface types contents

type t = {
  module_name : string;
  file : string;
  contents : Read.t;
  source_map_contents : Js_source_map.Standard.t option;
}

type import_status = Resolved of int * int | Unresolved of int

let check_limits export import =
  (* Beyond the min/max bounds, a memory or table type only matches an import
     when the address type (i32 / i64), the page size and the shared flag are
     the same — otherwise, e.g., an i32 memory would satisfy an i64 import.
     [page_size_log2 = None] denotes the default page (2^16), so normalise
     before comparing. *)
  export.address_type = import.address_type
  && export.shared = import.shared
  && Option.value ~default:16 export.page_size_log2
     = Option.value ~default:16 import.page_size_log2
  && Uint64.compare export.mi import.mi >= 0
  &&
  match (export.ma, import.ma) with
  | _, None -> true
  | None, Some _ -> false
  | Some e, Some i -> Uint64.compare e i <= 0

let subtype (info : link_subtyping_info) (i : int) (i' : int) =
  Wax_wasm.Types.heap_subtype info.wasm_info
    (Type (get_id info.types_map i))
    (Type (get_id info.types_map i'))

let val_subtype (info : link_subtyping_info) (ty : valtype) (ty' : valtype) =
  Wax_wasm.Types.val_subtype info.wasm_info
    (to_internal_valtype info.types_map ty)
    (to_internal_valtype info.types_map ty')

let check_export_import_types d ~subtyping_info ~files i (desc : importdesc) i'
    import =
  let ok =
    match (desc, import.desc) with
    | Func { typ = t; _ }, Func { typ = t'; _ } -> subtype subtyping_info t t'
    | ( Table { limits; reftype = typ },
        Table { limits = limits'; reftype = typ' } ) ->
        check_limits limits limits' && reftype_eq subtyping_info typ typ'
    | Memory limits, Memory limits' -> check_limits limits limits'
    | Global { mut; typ }, Global { mut = mut'; typ = typ' } ->
        mut = mut'
        &&
        if mut then valtype_eq subtyping_info typ typ'
        else val_subtype subtyping_info typ typ'
    | Tag t, Tag t' -> t = t'
    | _ -> false
  in
  if not ok then (
    Wax_utils.Diagnostic.report d ~location:dummy_loc ~severity:Error
      ~message:
        Wax_utils.Message.(
          (text "In module" ++ str files.(i').file)
          ^^ text "," ++ text "the import"
             ++ import_atom import.module_ import.name
             ++ text "refers to an export in module"
             ++ str files.(i).file
             ++ text "of an incompatible type.")
      ();
    Wax_utils.Diagnostic.abort ())

let build_mappings resolved_imports unresolved_imports kind counts =
  let current_offset = ref (get_exportable_info unresolved_imports kind) in
  let mappings =
    Array.mapi
      (fun i count ->
        let imports = get_exportable_info resolved_imports.(i) kind in
        let import_count = Array.length imports in
        let offset = !current_offset - import_count in
        current_offset := !current_offset + count;
        Array.init
          (Array.length imports + count)
          (fun i ->
            if i < import_count then
              match imports.(i) with Unresolved i -> i | Resolved _ -> -1
            else i + offset))
      counts
  in
  Array.iteri
    (fun i map ->
      let imports = get_exportable_info resolved_imports.(i) kind in
      for i = 0 to Array.length imports - 1 do
        match imports.(i) with
        | Unresolved _ -> ()
        | Resolved (j, k) -> map.(i) <- mappings.(j).(k)
      done)
    mappings;
  mappings

let build_simple_mappings ~counts =
  let current_offset = ref 0 in
  Array.map
    (fun count ->
      let offset = !current_offset in
      current_offset := !current_offset + count;
      Array.init count (fun j -> j + offset))
    counts

let add_section out_ch ~id ?count buf =
  match count with
  | Some 0 -> Buffer.clear buf
  | _ ->
      let buf' = Buffer.create 5 in
      Option.iter (fun c -> Write.uint buf' c) count;
      output_byte out_ch id;
      output_uint out_ch (Buffer.length buf' + Buffer.length buf);
      Buffer.output_buffer out_ch buf';
      Buffer.output_buffer out_ch buf;
      Buffer.clear buf

let add_subsection buf ~id ?count buf' =
  match count with
  | Some 0 -> Buffer.clear buf'
  | _ ->
      let buf'' = Buffer.create 5 in
      Option.iter (fun c -> Write.uint buf'' c) count;
      Buffer.add_char buf (Char.chr id);
      Write.uint buf (Buffer.length buf'' + Buffer.length buf');
      Buffer.add_buffer buf buf'';
      Buffer.add_buffer buf buf';
      Buffer.clear buf'

let check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
    ~files ~kind ~to_desc =
  Array.iteri
    (fun i intf ->
      let imports = get_exportable_info intf.Read.imports kind in
      let statuses = get_exportable_info resolved_imports.(i) kind in
      Array.iter2
        (fun import status ->
          match status with
          | Unresolved _ -> ()
          | Resolved (i', idx') -> (
              match to_desc i' idx' with
              | None -> ()
              | Some desc ->
                  check_export_import_types d ~subtyping_info ~files i' desc i
                    import))
        imports statuses)
    intfs

let read_desc_from_file ~intfs ~files ~positions ~read i j =
  let offset =
    Array.length (get_exportable_info intfs.(i).Read.imports Table)
  in
  if j < offset then None
  else
    let { contents; _ } = files.(i) in
    Read.seek_in contents.ch positions.(i).Scan.pos.(j - offset);
    Some (read contents)

let index_in_output ~unresolved_imports ~mappings ~kind ~get i' idx' =
  let offset = get_exportable_info unresolved_imports kind in
  let idx'' = mappings.(i').(idx') - offset in
  if idx'' >= 0 then Some (get idx'') else None

let write_simple_section d ~intfs ~subtyping_info ~resolved_imports
    ~unresolved_imports ~files ~out_ch ~kind ~read ~to_type ~write =
  let data = Array.map (fun f -> read f.contents) files in
  let entries = Array.concat (Array.to_list data) in
  if Array.length entries <> 0 then write out_ch entries;
  let counts = Array.map Array.length data in
  let mappings =
    build_mappings resolved_imports unresolved_imports kind counts
  in
  check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
    ~files ~kind
    ~to_desc:
      (index_in_output ~unresolved_imports ~mappings ~kind ~get:(fun idx ->
           to_type entries.(idx)));
  mappings

let write_section_with_scan ~types ~files ~out_ch ~buf ~id ~scan =
  let counts =
    Array.mapi
      (fun i { contents; _ } ->
        if Read.find_section contents id then (
          let count = Read.uint contents.ch in
          scan i
            {
              Scan.default_maps with
              typ = Read.get_type_mapping types contents;
            }
            buf contents.ch.buf ~count contents.ch.pos;
          count)
        else 0)
      files
  in
  add_section out_ch ~id ~count:(Array.fold_left ( + ) 0 counts) buf;
  counts

let write_simple_namemap ~name_sections ~name_section_buffer ~buf ~section_id
    ~mappings =
  let count = ref 0 in
  Array.iter2
    (fun name_section mapping ->
      if Read.find_section name_section section_id then (
        let map = Read.namemap name_section in
        Array.iter
          (fun (idx, name) -> Write.nameassoc buf mapping.(idx) name)
          map;
        count := !count + Array.length map))
    name_sections mappings;
  add_subsection name_section_buffer ~id:section_id ~count:!count buf

let write_namemap ~resolved_imports ~unresolved_imports ~name_sections
    ~name_section_buffer ~buf ~kind ~section_id ~mappings =
  let import_names =
    Array.make (get_exportable_info unresolved_imports kind) None
  in
  Array.iteri
    (fun i name_section ->
      if Read.find_section name_section section_id then
        let imports = get_exportable_info resolved_imports.(i) kind in
        let import_count = Array.length imports in
        let n = Read.uint name_section.ch in
        let rec loop j =
          if j < n then
            let idx = Read.uint name_section.ch in
            let name = Read.name name_section.ch in
            if idx < import_count then (
              let idx' =
                match imports.(idx) with
                | Unresolved idx' -> idx'
                | Resolved (i', idx') -> mappings.(i').(idx')
              in
              if
                idx' < Array.length import_names
                && Option.is_none import_names.(idx')
              then import_names.(idx') <- Some name;
              loop (j + 1))
        in
        loop 0)
    name_sections;
  let count = ref 0 in
  Array.iteri
    (fun idx name ->
      match name with
      | None -> ()
      | Some name ->
          incr count;
          Write.nameassoc buf idx name)
    import_names;
  Array.iteri
    (fun i name_section ->
      if Read.find_section name_section section_id then
        let mapping = mappings.(i) in
        let imports = get_exportable_info resolved_imports.(i) kind in
        let import_count = Array.length imports in
        let n = Read.uint name_section.ch in
        let ch = name_section.ch in
        for _ = 1 to n do
          let idx = Read.uint ch in
          let len = Read.uint ch in
          if idx >= import_count then (
            incr count;
            Write.uint buf mapping.(idx);
            Write.uint buf len;
            Buffer.add_substring buf ch.buf ch.pos len);
          ch.pos <- ch.pos + len
        done)
    name_sections;
  add_subsection name_section_buffer ~id:section_id ~count:!count buf

let write_indirectnamemap ~name_sections ~name_section_buffer ~buf ~section_id
    ~mappings =
  let count = ref 0 in
  Array.iter2
    (fun name_section mapping ->
      if Read.find_section name_section section_id then (
        let n = Read.uint name_section.ch in
        let scan_map = Scan.local_namemap buf name_section.ch.buf in
        for _ = 1 to n do
          let idx = mapping.(Read.uint name_section.ch) in
          Write.uint buf idx;
          let p = Buffer.length buf in
          scan_map name_section.ch.pos;
          name_section.ch.pos <- name_section.ch.pos + Buffer.length buf - p
        done;
        count := !count + n))
    name_sections mappings;
  add_subsection name_section_buffer ~id:section_id ~count:!count buf

let rec resolve d depth ~files ~intfs ~subtyping_info ~exports ~kind i
    ({ module_; name; _ } as import) =
  let i', index = Hashtbl.find exports (module_, name) in
  let imports = get_exportable_info intfs.(i').Read.imports kind in
  if index < Array.length imports then (
    if depth > 100 then (
      Wax_utils.Diagnostic.report d ~location:dummy_loc ~severity:Error
        ~message:
          Wax_utils.Message.(
            (text "Import loop on" ++ import_atom module_ name) ^^ text ".")
        ();
      Wax_utils.Diagnostic.abort ());
    let entry = imports.(index) in
    check_export_import_types d ~subtyping_info ~files i' entry.desc i import;
    try
      resolve d (depth + 1) ~files ~intfs ~subtyping_info ~exports ~kind i'
        entry
    with Not_found -> (i', index))
  else (i', index)

type input = {
  module_name : string;
  file : string;
  code : string option;
  opt_source_map : Js_source_map.Standard.t option;
}

let f ?(filter_export = fun _ -> true) files ~output_file =
  Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
    ~palette:Wax_utils.Colors.wat_theme ~source:None (fun d ->
      let files =
        Array.mapi
          (fun id { module_name; file; code; opt_source_map } ->
            let data =
              match code with
              | None -> In_channel.with_open_bin file In_channel.input_all
              | Some data -> data
            in
            let contents = Read.open_in id file data in
            {
              module_name;
              file;
              contents;
              source_map_contents = opt_source_map;
            })
          (Array.of_list files)
      in

      let out_ch = open_out_bin output_file in
      output_string out_ch Wax_wasm.Wasm_parser.header;
      let buf = Buffer.create 100000 in

      (* 1: type *)
      let types = Read.create_types (Array.length files) in
      let intfs = Array.map (fun f -> interface types f.contents) files in
      let subtyping_info =
        {
          wasm_info = Wax_wasm.Types.subtyping_info types.types_store;
          types_map = types.types_map;
        }
      in
      let binary_rectypes =
        List.map
          (fun (mapping, rectype) ->
            map_rectype (fun idx -> mapping.(idx)) rectype)
          (List.rev types.kept_rectypes)
      in
      ignore (Wax_wasm.Wasm_output.type_section out_ch binary_rectypes : int);

      (* 2: import *)
      let exports = init_exportable_info (fun _ -> Hashtbl.create 128) in
      Array.iteri
        (fun i intf ->
          iter_exportable_info
            (fun kind lst ->
              let h = get_exportable_info exports kind in
              List.iter
                (fun (name, index) ->
                  Hashtbl.add h (files.(i).module_name, name) (i, index))
                lst)
            intf.Read.exports)
        intfs;
      let import_list = ref [] in
      let unresolved_imports = make_exportable_info 0 in
      let resolved_imports =
        let tbl = Hashtbl.create 128 in
        Array.mapi
          (fun i intf ->
            map_exportable_info
              (fun kind imports ->
                let exports = get_exportable_info exports kind in
                Array.map
                  (fun (import : import) ->
                    match
                      resolve d 0 ~files ~intfs ~subtyping_info ~exports ~kind i
                        import
                    with
                    | i', idx -> Resolved (i', idx)
                    | exception Not_found -> (
                        match Hashtbl.find tbl import with
                        | status -> status
                        | exception Not_found ->
                            let idx =
                              get_exportable_info unresolved_imports kind
                            in
                            let status = Unresolved idx in
                            Hashtbl.replace tbl import status;
                            set_exportable_info unresolved_imports kind (1 + idx);
                            import_list := import :: !import_list;
                            status))
                  imports)
              intf.Read.imports)
          intfs
      in
      ignore
        (Wax_wasm.Wasm_output.import_section out_ch
           (List.rev_map (fun i -> Single i) !import_list)
          : int);

      let start_count =
        Array.fold_left
          (fun count f ->
            match Read.start f.contents with
            | None -> count
            | Some _ -> count + 1)
          0 files
      in

      (* 3: function *)
      let functions =
        Array.map (fun f -> Read.functions types f.contents) files
      in
      let func_types =
        let l = Array.to_list functions in
        let l =
          if start_count > 1 then
            let ty =
              let typ : comptype = Func { params = [||]; results = [||] } in
              Read.add_rectype types [||]
                [|
                  {
                    final = true;
                    supertype = None;
                    typ;
                    descriptor = None;
                    describes = None;
                  };
                |]
            in
            l @ [ [| ty |] ]
          else l
        in
        Array.concat l
      in
      ignore
        (Wax_wasm.Wasm_output.function_section out_ch (Array.to_list func_types)
          : int);
      let func_counts = Array.map Array.length functions in
      let func_mappings =
        build_mappings resolved_imports unresolved_imports Func func_counts
      in
      let func_count =
        Array.fold_left ( + ) (if start_count > 1 then 1 else 0) func_counts
      in
      check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
        ~files ~kind:Func
        ~to_desc:
          (index_in_output ~unresolved_imports ~mappings:func_mappings
             ~kind:Func ~get:(fun idx : importdesc ->
               Func { exact = false; typ = func_types.(idx) }));

      (* Global index maps, computed before the table section because a table's
         initializer expression may read a global ([(table … (global.get $g))]);
         the global bodies themselves are emitted later, in section 6. This
         reads each module's section-6 count but does not scan its bodies. *)
      let global_mappings = Array.make (Array.length files) [||] in
      let global_counts =
        let current_offset =
          ref (get_exportable_info unresolved_imports Global)
        in
        Array.mapi
          (fun i { file; contents; _ } ->
            let imports = get_exportable_info resolved_imports.(i) Global in
            let import_count = Array.length imports in
            let offset = !current_offset - import_count in
            let count =
              if Read.find_section contents 6 then Read.uint contents.ch else 0
            in
            let map =
              Array.init (import_count + count) (fun j ->
                  if j < import_count then (
                    match imports.(j) with
                    | Unresolved j' -> j'
                    | Resolved (i', j') ->
                        (if i' > i then
                           let import =
                             (get_exportable_info intfs.(i).imports Global).(j)
                           in
                           failwith
                             (Printf.sprintf
                                "In module %s, the import %s / %s refers to an \
                                 export in a later module %s"
                                file import.module_ import.name files.(i').file));
                        global_mappings.(i').(j'))
                  else j + offset)
            in
            global_mappings.(i) <- map;
            current_offset := !current_offset + count;
            count)
          files
      in

      (* 4: table *)
      let positions =
        Array.init (Array.length files) (fun _ -> Scan.create_position_data ())
      in
      let table_counts =
        write_section_with_scan ~types ~files ~out_ch ~buf ~id:4
          ~scan:(fun i maps ->
            Scan.table_section positions.(i)
              {
                maps with
                func = func_mappings.(i);
                global = global_mappings.(i);
              })
      in
      let table_mappings =
        build_mappings resolved_imports unresolved_imports Table table_counts
      in
      check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
        ~files ~kind:Table
        ~to_desc:
          (read_desc_from_file ~intfs ~files ~positions
             ~read:(fun contents : importdesc ->
               Table (Read.tabletype contents types contents.ch)));
      Array.iter Scan.clear_position_data positions;

      (* 5: memory *)
      let mem_mappings =
        write_simple_section d ~intfs ~subtyping_info ~resolved_imports
          ~unresolved_imports ~out_ch ~kind:Memory ~read:Read.memories
          ~to_type:(fun limits -> Memory limits)
          ~write:(fun ch entries ->
            ignore
              (Wax_wasm.Wasm_output.memory_section ch (Array.to_list entries)
                : int))
          ~files
      in

      (* 13: tag *)
      let tag_mappings =
        write_simple_section d ~intfs ~subtyping_info ~resolved_imports
          ~unresolved_imports ~out_ch ~kind:Tag ~read:(Read.tags types)
          ~to_type:(fun ty -> Tag ty)
          ~write:(fun ch entries ->
            ignore
              (Wax_wasm.Wasm_output.tag_section ch (Array.to_list entries)
                : int))
          ~files
      in

      (* 6: global (index maps already computed above) *)
      Array.iteri
        (fun i { contents; _ } ->
          if Read.find_section contents 6 then
            let count = Read.uint contents.ch in
            Scan.global_section positions.(i)
              {
                Scan.default_maps with
                typ = Read.get_type_mapping types contents;
                func = func_mappings.(i);
                global = global_mappings.(i);
              }
              buf contents.ch.buf contents.ch.pos ~count)
        files;
      add_section out_ch ~id:6
        ~count:(Array.fold_left ( + ) 0 global_counts)
        buf;
      check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
        ~files ~kind:Global ~to_desc:(fun i j : importdesc option ->
          let offset =
            Array.length (get_exportable_info intfs.(i).imports Global)
          in
          if j < offset then None
          else
            let { contents; _ } = files.(i) in
            Read.seek_in contents.ch positions.(i).pos.(j - offset);
            Some (Global (Read.globaltype contents types contents.ch)));
      Array.iter Scan.clear_position_data positions;

      (* 7: export *)
      let exports =
        Array.map
          (fun intf ->
            map_exportable_info
              (fun _ exports ->
                List.filter (fun (nm, _) -> filter_export nm) exports)
              intf.Read.exports)
          intfs
      in
      let export_tbl = StringHashtbl.create 128 in
      let export_list = ref [] in
      Array.iteri
        (fun i exports ->
          iter_exportable_info
            (fun kind lst ->
              let map =
                match kind with
                | Func -> func_mappings.(i)
                | Table -> table_mappings.(i)
                | Memory -> mem_mappings.(i)
                | Global -> global_mappings.(i)
                | Tag -> tag_mappings.(i)
              in
              List.iter
                (fun (name, idx) ->
                  match StringHashtbl.find export_tbl name with
                  | i' ->
                      Wax_utils.Diagnostic.report d ~location:dummy_loc
                        ~severity:Error
                        ~message:
                          Wax_utils.Message.(
                            text "Duplicated export" ++ str name
                            ++ text "found in multiple input modules:"
                            ++ str files.(i').file ++ text "and"
                            ++ str files.(i).file
                            ^^ text ".")
                        ();
                      Wax_utils.Diagnostic.abort ()
                  | exception Not_found ->
                      StringHashtbl.add export_tbl name i;
                      let index = map.(idx) in
                      export_list := { name; kind; index } :: !export_list)
                lst)
            exports)
        exports;
      ignore
        (Wax_wasm.Wasm_output.export_section out_ch (List.rev !export_list)
          : int);

      (* 8: start *)
      let starts =
        Array.mapi
          (fun i f ->
            Read.start f.contents
            |> Option.map (fun idx -> func_mappings.(i).(idx)))
          files
        |> Array.to_list
        |> List.filter_map (fun x -> x)
      in
      (match starts with
      | [] -> ()
      | [ start ] ->
          ignore (Wax_wasm.Wasm_output.start_section out_ch start : int)
      | _ :: _ :: _ ->
          ignore
            (Wax_wasm.Wasm_output.start_section out_ch
               (get_exportable_info unresolved_imports Func + func_count - 1)
              : int));

      (* 9: elements *)
      let elem_counts =
        write_section_with_scan ~types ~files ~out_ch ~buf ~id:9
          ~scan:(fun i maps ->
            Scan.elem_section
              {
                maps with
                func = func_mappings.(i);
                table = table_mappings.(i);
                global = global_mappings.(i);
              })
      in
      let elem_mappings = build_simple_mappings ~counts:elem_counts in

      (* 12: data count *)
      let data_mappings, data_count =
        let data_counts =
          Array.map (fun f -> Read.data_count f.contents) files
        in
        let data_count = Array.fold_left ( + ) 0 data_counts in
        let data_mappings = build_simple_mappings ~counts:data_counts in
        (data_mappings, data_count)
      in
      if data_count > 0 then
        ignore (Wax_wasm.Wasm_output.datacount_section out_ch data_count : int);

      (* 10: code *)
      let code_pieces = Buffer.create 100000 in
      let resize_data = Scan.create_resize_data () in
      let source_maps = ref [] in
      let linked_branch_hints = ref [] in
      Write.uint code_pieces func_count;
      Array.iteri
        (fun i { contents; source_map_contents; _ } ->
          if Read.find_section contents 10 then (
            let pos = Buffer.length code_pieces in
            let scan_func =
              Scan.func resize_data
                {
                  typ = Read.get_type_mapping types contents;
                  func = func_mappings.(i);
                  table = table_mappings.(i);
                  mem = mem_mappings.(i);
                  global = global_mappings.(i);
                  elem = elem_mappings.(i);
                  data = data_mappings.(i);
                  tag = tag_mappings.(i);
                }
                buf contents.ch.buf
            in
            let count = Read.uint contents.ch in
            let func_starts = Array.make count 0 in
            let func_idx = ref 0 in
            let code (ch : Read.ch) =
              let pos = ch.pos in
              let idx = resize_data.i in
              let size = Read.uint ch in
              let pos' = ch.pos in
              func_starts.(!func_idx) <- pos';
              incr func_idx;
              Scan.push_resize resize_data pos' 0;
              scan_func ch.pos;
              ch.pos <- ch.pos + size;
              let p = Buffer.length code_pieces in
              Write.uint code_pieces (Buffer.length buf);
              let p' = Buffer.length code_pieces in
              let delta = p' - p - pos' + pos in
              resize_data.delta.(idx) <- delta;
              Buffer.add_buffer code_pieces buf;
              Buffer.clear buf
            in
            Scan.clear_resize_data resize_data;
            Scan.push_resize resize_data 0 (-Read.pos_in contents.ch);
            Read.repeat' count code contents.ch;
            let branch_hint_section =
              Read.focus_on_custom_section_payload contents
                "metadata.code.branch_hint"
            in
            let hints = read_branch_hints branch_hint_section in
            let import_count =
              Array.length (get_exportable_info resolved_imports.(i) Func)
            in
            let idx = ref 0 in
            let acc = ref 0 in
            let shift x =
              while !idx < resize_data.i && x >= resize_data.pos.(!idx) do
                acc := !acc + resize_data.delta.(!idx);
                incr idx
              done;
              x + !acc
            in
            List.iter
              (fun (funcidx, hints_list) ->
                let k = funcidx - import_count in
                if k >= 0 && k < count then
                  let pos' = func_starts.(k) in
                  let pos'_shifted = shift pos' in
                  let mapped_hints =
                    List.map
                      (fun (offset, hint) ->
                        let branch_pos = pos' + offset in
                        let branch_pos_shifted = shift branch_pos in
                        let new_offset = branch_pos_shifted - pos'_shifted in
                        (new_offset, hint))
                      hints_list
                  in
                  let new_funcidx = func_mappings.(i).(funcidx) in
                  linked_branch_hints :=
                    (new_funcidx, mapped_hints) :: !linked_branch_hints)
              hints;
            Option.iter
              (fun sm ->
                if not (Js_source_map.is_empty sm) then
                  source_maps :=
                    (pos, Js_source_map.resize resize_data sm) :: !source_maps)
              source_map_contents))
        files;
      if start_count > 1 then (
        (* no local *)
        Buffer.add_char buf (Char.chr 0);
        List.iter
          (fun idx ->
            (* call idx *)
            Buffer.add_char buf (Char.chr 0x10);
            Write.uint buf idx)
          starts;
        (* end *)
        Buffer.add_char buf (Char.chr 0x0B);
        Write.uint code_pieces (Buffer.length buf);
        Buffer.add_buffer code_pieces buf;
        Buffer.clear buf);
      let code_section_offset =
        let b = Buffer.create 5 in
        Write.uint b (Buffer.length code_pieces);
        pos_out out_ch + 1 + Buffer.length b
      in
      add_section out_ch ~id:10 code_pieces;
      let sorted_branch_hints = List.rev !linked_branch_hints in
      if sorted_branch_hints <> [] then
        ignore
          (Wax_wasm.Wasm_output.output_branch_hint_section out_ch
             sorted_branch_hints
            : int);
      let source_map =
        Js_source_map.concatenate
          (List.map
             (fun (pos, sm) -> (pos + code_section_offset, sm))
             (List.rev !source_maps))
      in

      (* 11: data *)
      ignore
        (write_section_with_scan ~types ~files ~out_ch ~buf ~id:11
           ~scan:(fun i maps ->
             Scan.data_section
               {
                 maps with
                 mem = mem_mappings.(i);
                 global = global_mappings.(i);
               }));

      (* Custom section: name *)
      let name_sections =
        Array.map
          (fun { contents; _ } -> Read.focus_on_custom_section contents "name")
          files
      in
      let name_section_buffer = Buffer.create 100000 in
      Write.name name_section_buffer "name";

      (* 1: functions *)
      write_namemap ~resolved_imports ~unresolved_imports ~name_sections
        ~name_section_buffer ~buf ~kind:Func ~section_id:1
        ~mappings:func_mappings;
      (* 2: locals *)
      write_indirectnamemap ~name_sections ~name_section_buffer ~buf
        ~section_id:2 ~mappings:func_mappings;
      (* 3: labels *)
      write_indirectnamemap ~name_sections ~name_section_buffer ~buf
        ~section_id:3 ~mappings:func_mappings;

      (* 4: types *)
      let type_names =
        Array.make (Wax_wasm.Types.last_index types.types_store) None
      in
      Array.iter2
        (fun { contents; _ } name_section ->
          if Read.find_section name_section 4 then
            let map = Read.namemap name_section in
            Array.iter
              (fun (idx, name) ->
                let idx = (Read.get_type_mapping types contents).(idx) in
                if Option.is_none type_names.(idx) then
                  type_names.(idx) <- Some (idx, name))
              map)
        files name_sections;
      Write.namemap buf
        (Array.of_list
           (List.filter_map (fun x -> x) (Array.to_list type_names)));
      add_subsection name_section_buffer ~id:4 buf;

      (* 5: tables *)
      write_namemap ~resolved_imports ~unresolved_imports ~name_sections
        ~name_section_buffer ~buf ~kind:Table ~section_id:5
        ~mappings:table_mappings;
      (* 6: memories *)
      write_namemap ~resolved_imports ~unresolved_imports ~name_sections
        ~name_section_buffer ~buf ~kind:Memory ~section_id:6
        ~mappings:mem_mappings;
      (* 7: globals *)
      write_namemap ~resolved_imports ~unresolved_imports ~name_sections
        ~name_section_buffer ~buf ~kind:Global ~section_id:7
        ~mappings:global_mappings;
      (* 8: elems *)
      write_simple_namemap ~name_sections ~name_section_buffer ~buf
        ~section_id:8 ~mappings:elem_mappings;
      (* 9: data segments *)
      write_simple_namemap ~name_sections ~name_section_buffer ~buf
        ~section_id:9 ~mappings:data_mappings;

      (* 10: field names *)
      let type_field_names =
        Array.make (Wax_wasm.Types.last_index types.types_store) None
      in
      Array.iter2
        (fun { contents; _ } name_section ->
          if Read.find_section name_section 10 then
            let n = Read.uint name_section.ch in
            let scan_map = Scan.local_namemap buf name_section.ch.buf in
            for _ = 1 to n do
              let idx =
                (Read.get_type_mapping types contents).(Read.uint
                                                          name_section.ch)
              in
              scan_map name_section.ch.pos;
              name_section.ch.pos <- name_section.ch.pos + Buffer.length buf;
              if Option.is_none type_field_names.(idx) then
                type_field_names.(idx) <- Some (idx, Buffer.contents buf);
              Buffer.clear buf
            done)
        files name_sections;
      let type_field_names =
        Array.of_list
          (List.filter_map (fun x -> x) (Array.to_list type_field_names))
      in
      Write.uint buf (Array.length type_field_names);
      for i = 0 to Array.length type_field_names - 1 do
        let idx, map = type_field_names.(i) in
        Write.uint buf idx;
        Buffer.add_string buf map
      done;
      add_subsection name_section_buffer ~id:10 buf;

      (* 11: tags *)
      write_namemap ~resolved_imports ~unresolved_imports ~name_sections
        ~name_section_buffer ~buf ~kind:Tag ~section_id:11
        ~mappings:tag_mappings;

      add_section out_ch ~id:0 name_section_buffer;

      close_out out_ch;

      source_map)

let get_instruction_offsets ~filename buf =
  let offsets = ref [] in
  let mark pos = offsets := pos :: !offsets in
  let count = ref 0 in
  Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
    ~palette:Wax_utils.Colors.wat_theme ~source:(Some buf) (fun d ->
      let ch = Wax_wasm.Wasm_parser.make_ch d ~filename buf 0 in
      Wax_wasm.Wasm_parser.check_header ch;
      ch.pos <- 8;
      let index = Wax_wasm.Wasm_parser.index ch in
      let contents = { Read.id = 0; ch; index } in
      if Read.find_section contents 10 then (
        let count' = Read.uint contents.ch in
        count := count';
        let code (ch : Wax_wasm.Wasm_parser.ch) =
          let size = Read.uint ch in
          let pos' = ch.pos in
          let _, _, _, _, func, _ =
            Scan.scanner ~mark_instructions:true
              (fun _ _ -> ())
              mark Scan.default_maps (Buffer.create 0) ch.buf
          in
          let _ = func pos' in
          ch.pos <- ch.pos + size
        in
        Read.repeat' count' code contents.ch));
  (List.rev !offsets, !count)
