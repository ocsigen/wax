open Ast
open Ast.Text
module StringMap = Map.Make (String)
module StringSet = Set.Make (String)

(* The top-level value-type aliases, to see through one written as the field
   type of a JavaScript-string struct. *)
let aliases fields =
  List.fold_left
    (fun m (f : (_ modulefield, _) Ast.annotated) ->
      match f.desc with
      | Type_alias { id; typ } -> StringMap.add id.Ast.desc typ m
      | _ -> m)
    StringMap.empty fields

let rec expand_alias aliases seen (t : valtype) =
  match t with
  | Alias a ->
      if List.mem a.Ast.desc seen then None
      else
        Option.bind
          (StringMap.find_opt a.desc aliases)
          (expand_alias aliases (a.desc :: seen))
  | I32 | I64 | F32 | F64 | V128 | Ref _ -> Some t

(* The module's type definitions, in index order. *)
let type_defs fields =
  List.concat_map
    (fun (f : (_ modulefield, _) Ast.annotated) ->
      match f.desc with
      | Types r -> Array.to_list (Array.map (fun e -> e.Ast.desc) r)
      | _ -> [])
    fields

let lookup_type defs (idx : idx) =
  match idx.desc with
  | Num n -> Option.map snd (List.nth_opt defs (Uint32.to_int n))
  | Id id ->
      List.find_map
        (fun ((n : name option), st) ->
          match n with Some n when n.desc = id -> Some st | _ -> None)
        defs

(* How a string literal building a [t] is lowered when it builds a JavaScript
   string: [`Extern] for a plain [externref] string, [`Wrapped (idx, field)]
   for a struct [idx] whose single field is an [anyref] ([field] is [`Any]: the
   external reference is internalized) or an [externref]. [None] for an array,
   which the callers lower themselves. *)
let js_string aliases defs (t : heaptype) =
  match t with
  | Extern -> Some `Extern
  | Type idx | Exact idx -> (
      match lookup_type defs idx with
      | Some { typ = Struct [| field |]; _ } -> (
          match (snd field.Ast.desc).typ with
          | Value t -> (
              match expand_alias aliases [] t with
              | Some (Ref { typ = Any; _ }) -> Some (`Wrapped (idx, `Any))
              | Some (Ref { typ = Extern; _ }) -> Some (`Wrapped (idx, `Extern))
              | Some _ | None -> None)
          | Packed _ -> None)
      | _ -> None)
  | Func | NoFunc | Exn | NoExn | Cont | NoCont | NoExtern | Any | Eq | I31
  | Struct | Array | None_ ->
      None

(* A bottom-up map of [f] over an instruction and the instructions nested in it.
   A conditional annotation is left as is, for the caller to report. *)
let rec map_instr f (i : _ instr) =
  { i with desc = f { i with desc = map_desc f i.desc } }

and map_block f (b : (_ instr list, _) Ast.annotated) =
  { b with desc = List.map (map_instr f) b.desc }

and map_desc f (desc : _ instr_desc) : _ instr_desc =
  match desc with
  | Block b -> Block { b with block = map_block f b.block }
  | Loop b -> Loop { b with block = map_block f b.block }
  | If b ->
      If
        {
          b with
          if_block = map_block f b.if_block;
          else_block = map_block f b.else_block;
        }
  | TryTable b -> TryTable { b with block = map_block f b.block }
  | Try b ->
      Try
        {
          b with
          block = map_block f b.block;
          catches = List.map (fun (t, l) -> (t, map_block f l)) b.catches;
          catch_all = Option.map (map_block f) b.catch_all;
        }
  | Folded (h, l) -> (
      let h = map_instr f h in
      let l = List.map (map_instr f) l in
      (* A string literal written as a folded head with no operand expands to
         a folded instruction itself: no redundant parenthesis is left. *)
      match (h.desc, l) with
      | (Folded _ as d), [] -> d
      | _ -> Folded (h, l))
  | desc -> desc

(* Apply [f] to every instruction of a field; [f] returns the new description
   of the instruction it is passed. *)
let map_field_instrs f (fl : (_ modulefield, _) Ast.annotated) =
  let instrs = List.map (map_instr f) in
  let desc : _ modulefield =
    match fl.desc with
    | Func r -> Func { r with instrs = instrs r.instrs }
    | Global r -> Global { r with init = instrs r.init }
    | Table r ->
        let init : _ tableinit =
          match r.init with
          | Init_default -> Init_default
          | Init_expr e -> Init_expr (instrs e)
          | Init_segment segs -> Init_segment (List.map instrs segs)
        in
        Table { r with init }
    | Elem r ->
        let mode : _ elemmode =
          match r.mode with
          | Active (idx, e) -> Active (idx, instrs e)
          | (Passive | Declare) as mode -> mode
        in
        Elem { r with init = List.map instrs r.init; mode }
    | Data r ->
        let mode : _ datamode =
          match r.mode with
          | Active (idx, e) -> Active (idx, instrs e)
          | Passive as mode -> mode
        in
        Data { r with mode }
    | desc -> desc
  in
  { fl with desc }

let is_import (f : (_ modulefield, _) Ast.annotated) =
  match f.desc with
  | Import _ | Import_group1 _ | Import_group2 _ -> true
  | _ -> false

(* The ids bound in the global index space, to keep a synthesised one fresh. *)
let global_names fields =
  List.fold_left
    (fun s (f : (_ modulefield, _) Ast.annotated) ->
      match f.desc with
      | Global { id = Some id; _ }
      | Import { id = Some id; desc = Global _; _ }
      | String_global { id; _ } ->
          StringSet.add id.desc s
      | _ -> s)
    StringSet.empty
    (List.concat_map Ast_utils.expand_import_group fields)

let imported_global_count fields =
  List.length
    (List.filter
       (fun (f : (_ modulefield, _) Ast.annotated) ->
         match f.desc with Import { desc = Global _; _ } -> true | _ -> false)
       (List.concat_map Ast_utils.expand_import_group fields))

(* Shift by [n] every numeric reference to a global the module defines (one
   at index [first] or above), past the [n] imports inserted before them. *)
let shift_globals ~first ~n fields =
  let shift (idx : idx) =
    match idx.desc with
    | Num k when Uint32.to_int k >= first ->
        { idx with desc = Num (Uint32.of_int (Uint32.to_int k + n)) }
    | Num _ | Id _ -> idx
  in
  List.map
    (fun (f : (_ modulefield, _) Ast.annotated) ->
      let f =
        map_field_instrs
          (fun (i : _ instr) ->
            match i.desc with
            | GlobalGet idx -> GlobalGet (shift idx)
            | GlobalSet idx -> GlobalSet (shift idx)
            | desc -> desc)
          f
      in
      match f.desc with
      | Export ({ kind = Global; index; _ } as r) ->
          { f with desc = Export { r with index = shift index } }
      | _ -> f)
    fields

exception Missing_string_imports of location

let has_conditional fields =
  List.exists
    (fun (f : (_ modulefield, _) Ast.annotated) ->
      match f.desc with
      | Module_if_annotation _ -> true
      | _ ->
          let found = ref false in
          ignore
            (map_field_instrs
               (fun (i : _ instr) ->
                 (match i.desc with
                 | If_annotation _ -> found := true
                 | _ -> ());
                 i.desc)
               f);
          !found)
    fields

let module_ ((name, fields) as m : location module_) : location module_ =
  let string_type =
    List.find_map
      (fun (f : (_ modulefield, _) Ast.annotated) ->
        match f.desc with String_type t -> Some t | _ -> None)
      fields
  in
  let string_imports =
    List.find_map
      (fun (f : (_ modulefield, _) Ast.annotated) ->
        match f.desc with String_imports n -> Some n | _ -> None)
      fields
  in
  let aliases = aliases fields in
  let defs = type_defs fields in
  let used = global_names fields in
  (* The string constants to import, as text -> global id, and in order. *)
  let constants = Hashtbl.create 16 in
  let imports = ref [] in
  let counter = ref 0 in
  let rec fresh () =
    let id = "<js-string>" ^ string_of_int !counter in
    incr counter;
    if StringSet.mem id used then fresh () else id
  in
  let constant loc text =
    match Hashtbl.find_opt constants text with
    | Some id -> id
    | None ->
        let id = fresh () in
        Hashtbl.add constants text id;
        imports := (loc, text, id) :: !imports;
        id
  in
  (* The type a literal builds: the one it names, or else the designated one. *)
  let literal_type t = match t with Some _ -> t | None -> string_type in
  (* For a literal building a JavaScript string, the instruction building it
     and the type of its value. *)
  let js_literal loc t s : (location instr_desc * valtype) option =
    match literal_type t with
    | None -> None
    | Some t -> (
        match js_string aliases defs t with
        | None -> None
        | Some repr -> (
            if string_imports = None then raise (Missing_string_imports loc);
            let at desc : location instr =
              { desc; info = loc; hints = Hints.none }
            in
            let id = constant loc (Wax_utils.Ast.concat_desc s) in
            let get = GlobalGet { desc = Id id; info = loc } in
            match repr with
            | `Extern ->
                Some
                  (Folded (at get, []), Ref { nullable = false; typ = Extern })
            | `Wrapped (idx, field) ->
                let value =
                  match field with
                  | `Any ->
                      at
                        (Folded
                           (at AnyConvertExtern, [ at (Folded (at get, [])) ]))
                  | `Extern -> at (Folded (at get, []))
                in
                Some
                  ( Folded (at (StructNew idx), [ value ]),
                    Ref { nullable = false; typ = Type idx } )))
  in
  if has_conditional fields then
    (* Left for the caller to report: no string setting can be relied on. *)
    m
  else if string_type = None && string_imports = None then (
    (* Without either setting no literal builds a JavaScript string, except a
       [(@string extern …)] or one building a JavaScript-string struct, which
       then lacks the import module. *)
    let check (i : location instr) =
      match i.desc with
      | String (t, s) -> ignore (js_literal i.info t s)
      | _ -> ()
    in
    List.iter
      (fun (f : (location modulefield, location) Ast.annotated) ->
        match f.desc with
        | String_global { typ; init; _ } -> ignore (js_literal f.info typ init)
        | _ ->
            ignore
              (map_field_instrs
                 (fun i ->
                   check i;
                   i.desc)
                 f))
      fields;
    m)
  else
    let fields =
      List.filter_map
        (fun (f : (location modulefield, location) Ast.annotated) ->
          match f.desc with
          | String_type _ | String_imports _ -> None
          | String_global { id; typ; init } -> (
              match js_literal f.info typ init with
              | Some (desc, typ) ->
                  Some
                    {
                      f with
                      desc =
                        Global
                          {
                            id = Some id;
                            typ = { mut = false; typ };
                            init =
                              [ { desc; info = f.info; hints = Hints.none } ];
                            exports = [];
                          };
                    }
              | None ->
                  Some
                    {
                      f with
                      desc = String_global { id; typ = literal_type typ; init };
                    })
          | _ ->
              Some
                (map_field_instrs
                   (fun (i : location instr) ->
                     match i.desc with
                     | String (t, s) -> (
                         match js_literal i.info t s with
                         | Some (desc, _) -> desc
                         | None -> String (literal_type t, s))
                     | desc -> desc)
                   f))
        fields
    in
    match !imports with
    | [] -> (name, fields)
    | imports ->
        let module_ = Option.get string_imports in
        let fields =
          shift_globals
            ~first:(imported_global_count fields)
            ~n:(List.length imports) fields
        in
        let imports =
          List.rev_map
            (fun (loc, text, id) ->
              {
                Ast.desc =
                  Import
                    {
                      module_;
                      name = { desc = text; info = loc };
                      id = Some { desc = id; info = loc };
                      desc =
                        Global
                          {
                            mut = false;
                            typ = Ref { nullable = false; typ = Extern };
                          };
                      exports = [];
                    };
                info = loc;
              })
            imports
        in
        (* After the module's own imports, since an import precedes every
           definition. *)
        let last_import =
          snd
            (List.fold_left
               (fun (i, last) f ->
                 (i + 1, if is_import f then Some i else last))
               (0, None) fields)
        in
        let fields =
          match last_import with
          | None -> imports @ fields
          | Some k ->
              List.concat
                (List.mapi
                   (fun i f -> if i = k then f :: imports else [ f ])
                   fields)
        in
        (name, fields)
