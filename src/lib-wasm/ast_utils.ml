open Ast
open Ast.Text

(* The canonical pre-order walk of an instruction tree: visit [i], then recurse
   into every nested instruction it carries. Keeping this in one place means a
   new instruction that nests others is handled for every traversal at once. *)
let rec fold_instr f acc (i : 'info instr) =
  let acc = f acc i in
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      fold_instrs f acc block.desc
  | If { if_block; else_block; _ } ->
      fold_instrs f (fold_instrs f acc if_block.desc) else_block.desc
  | Try { block; catches; catch_all; _ } ->
      let acc = fold_instrs f acc block.desc in
      let acc =
        List.fold_left
          (fun acc (_, (is : (_ instr list, _) Ast.annotated)) ->
            fold_instrs f acc is.desc)
          acc catches
      in
      Option.fold ~none:acc
        ~some:(fun (b : (_ instr list, _) Ast.annotated) ->
          fold_instrs f acc b.desc)
        catch_all
  | Folded (h, is) -> fold_instrs f (fold_instr f acc h) is
  (* The remaining variants carry no nested instruction. *)
  | _ -> acc

and fold_instrs f acc l =
  (* Explicit recursion, not [List.fold_left (fold_instr f)]: this runs once per
     nested instruction list, and the partial application [(fold_instr f)] would
     allocate a closure on every call. *)
  match l with
  | [] -> acc
  | i :: r -> fold_instrs f (fold_instr f acc i) r

let iter_instr f i = fold_instr (fun () i -> f i) () i

(* compact-import-section: expand an [Import_group1]/[Import_group2] field into
   the individual [Import] fields it stands for (carrying the group's location);
   any other field is returned unchanged as a singleton. Passes that only need to
   see individual imports flatten a field list with
   [List.concat_map expand_import_group]. *)
let expand_import_group (f : (_ modulefield, _) Ast.annotated) =
  match f.desc with
  | Import_group1 { module_; items } ->
      List.map
        (fun (name, id, desc) ->
          { f with desc = Import { module_; name; id; desc; exports = [] } })
        items
  | Import_group2 { module_; desc; items } ->
      List.map
        (fun name ->
          {
            f with
            desc = Import { module_; name; id = None; desc; exports = [] };
          })
        items
  | _ -> [ f ]

(* Flatten binary import-section entries back into the individual imports they
   denote, for the passes that only need the flat import list (index counting). *)
let flatten_binary_imports (entries : Ast.Binary.import_entry list) :
    Ast.Binary.import list =
  List.concat_map
    (function
      | Ast.Binary.Single i -> [ i ]
      | Group1 { module_; items } ->
          List.map
            (fun (name, desc) -> { Ast.Binary.module_; name; desc })
            items
      | Group2 { module_; desc; names } ->
          List.map (fun name -> { Ast.Binary.module_; name; desc }) names)
    entries

(* Value-type aliases. An alias stands for a whole value type, and a reference
   type never contains one, so only a value type's outermost constructor can be
   an alias use. *)
let type_aliases (fields : (_ modulefield, _) Ast.annotated list) =
  let tbl = Hashtbl.create 8 in
  List.iter
    (fun (f : (_ modulefield, _) Ast.annotated) ->
      match f.desc with
      | Type_alias { id; typ } ->
          if not (Hashtbl.mem tbl id.Ast.desc) then
            Hashtbl.add tbl id.Ast.desc typ
      | _ -> ())
    fields;
  tbl

let expand_alias aliases (t : valtype) =
  let rec expand seen (t : valtype) =
    match t with
    | Alias a ->
        if List.mem a.Ast.desc seen then raise Not_found;
        expand (a.desc :: seen) (Hashtbl.find aliases a.desc)
    | I32 | I64 | F32 | F64 | V128 | Ref _ -> t
  in
  expand [] t

let map_typeuse f ((idx, sign) : typeuse) : typeuse =
  ( idx,
    Option.map
      (fun ({ params; results } : functype) : functype ->
        {
          params =
            Array.map
              (fun (p : (_ * valtype, _) Ast.annotated) ->
                { p with desc = (fst p.desc, f (snd p.desc)) })
              params;
          results = Array.map f results;
        })
      sign )

let map_storagetype f (t : storagetype) =
  match t with Value v -> Value (f v) | Packed _ -> t

let map_comptype f (t : comptype) : comptype =
  match t with
  | Func sign -> (
      match map_typeuse f (None, Some sign) with
      | _, Some sign -> Func sign
      | _, None -> assert false)
  | Struct fields ->
      Struct
        (Array.map
           (fun (fl : (_ * fieldtype, _) Ast.annotated) ->
             let name, ft = fl.desc in
             {
               fl with
               desc = (name, { ft with typ = map_storagetype f ft.typ });
             })
           fields)
  | Array ft -> Array { ft with typ = map_storagetype f ft.typ }
  | Cont _ -> t

let map_importdesc f (d : importdesc) : importdesc =
  match d with
  | Func r -> Func { r with typ = map_typeuse f r.typ }
  | Global g -> Global { g with typ = f g.typ }
  | Tag tu -> Tag (map_typeuse f tu)
  | Memory _ | Table _ -> d

let map_blocktype f (t : blocktype option) =
  Option.map
    (fun (t : blocktype) : blocktype ->
      match t with
      | Valtype v -> Valtype (f v)
      | Typeuse tu -> Typeuse (map_typeuse f tu))
    t

let rec map_instr_valtypes f (i : 'info instr) : 'info instr =
  let instrs (l : ('info instr list, _) Ast.annotated) =
    { l with desc = List.map (map_instr_valtypes f) l.desc }
  in
  let desc : 'info instr_desc =
    match i.desc with
    | Block b ->
        Block { b with typ = map_blocktype f b.typ; block = instrs b.block }
    | Loop b ->
        Loop { b with typ = map_blocktype f b.typ; block = instrs b.block }
    | If b ->
        If
          {
            b with
            typ = map_blocktype f b.typ;
            if_block = instrs b.if_block;
            else_block = instrs b.else_block;
          }
    | TryTable b ->
        TryTable { b with typ = map_blocktype f b.typ; block = instrs b.block }
    | Try b ->
        Try
          {
            b with
            typ = map_blocktype f b.typ;
            block = instrs b.block;
            catches = List.map (fun (t, l) -> (t, instrs l)) b.catches;
            catch_all = Option.map instrs b.catch_all;
          }
    | CallIndirect (t, tu) -> CallIndirect (t, map_typeuse f tu)
    | ReturnCallIndirect (t, tu) -> ReturnCallIndirect (t, map_typeuse f tu)
    | Select (Some l) -> Select (Some (List.map f l))
    | Folded (h, l) ->
        Folded (map_instr_valtypes f h, List.map (map_instr_valtypes f) l)
    | If_annotation r ->
        If_annotation
          {
            r with
            then_body = instrs r.then_body;
            else_body = Option.map instrs r.else_body;
          }
    | desc -> desc
  in
  { i with desc }

let rec map_field_valtypes f (fl : ('info modulefield, _) Ast.annotated) =
  let instrs = List.map (map_instr_valtypes f) in
  let desc : 'info modulefield =
    match fl.desc with
    | Types r ->
        Types
          (Array.map
             (fun (e : (_ * subtype, _) Ast.annotated) ->
               let name, st = e.desc in
               { e with desc = (name, { st with typ = map_comptype f st.typ }) })
             r)
    | Import r -> Import { r with desc = map_importdesc f r.desc }
    | Import_group1 r ->
        Import_group1
          {
            r with
            items =
              List.map
                (fun (name, id, d) -> (name, id, map_importdesc f d))
                r.items;
          }
    | Import_group2 r -> Import_group2 { r with desc = map_importdesc f r.desc }
    | Func r ->
        Func
          {
            r with
            typ = map_typeuse f r.typ;
            locals =
              List.map
                (fun (l : (_ * valtype, _) Ast.annotated) ->
                  { l with desc = (fst l.desc, f (snd l.desc)) })
                r.locals;
            instrs = instrs r.instrs;
          }
    | Tag r -> Tag { r with typ = map_typeuse f r.typ }
    | Global r ->
        Global
          {
            r with
            typ = { r.typ with typ = f r.typ.typ };
            init = instrs r.init;
          }
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
    | Type_alias r -> Type_alias { r with typ = f r.typ }
    | Module_if_annotation r ->
        let fields (l : (_ list, _) Ast.annotated) =
          { l with desc = List.map (map_field_valtypes f) l.desc }
        in
        Module_if_annotation
          {
            r with
            then_fields = fields r.then_fields;
            else_fields = Option.map fields r.else_fields;
          }
    | Memory _ | Export _ | Start _ | String_global _ | Feature_annotation _ ->
        fl.desc
  in
  { fl with desc }

let expand_type_aliases ~unbound fields =
  let aliases = type_aliases fields in
  List.filter_map
    (fun (f : (_ modulefield, _) Ast.annotated) ->
      match f.desc with
      | Type_alias _ -> None
      | _ ->
          Some
            (map_field_valtypes
               (fun (t : valtype) ->
                 try expand_alias aliases t
                 with Not_found -> (
                   match t with Alias a -> unbound a | _ -> assert false))
               f))
    fields
