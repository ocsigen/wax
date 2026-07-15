open Ast
module Text = Ast.Text

type kind =
  | Func
  | Global
  | Type
  | Param
  | Local
  | Label
  | Memory
  | Table
  | Tag
  | Elem
  | Data
  | Field

type binding = {
  def : location option;
  uses : location list;
  kind : kind;
  hover : string option;
}

(* Internal mutable accumulator (uses grow as the walk finds references); mapped
   to the immutable {!binding} at the end. *)
type acc = {
  a_def : location option;
  mutable a_uses : location list;
  a_kind : kind;
  a_hover : string option;
}

(* One index space (functions, globals, types, …): definitions numbered in
   declaration order, indexed by both their numeric position and their [$id]. *)
type space = {
  s_kind : kind;
  mutable s_next : int;
  s_by_name : (string, acc) Hashtbl.t;
  s_by_index : (int, acc) Hashtbl.t;
}

let f ((_, fields) : location Text.module_) : binding list =
  let all = ref [] in
  let add_binding kind def hover =
    let b = { a_def = def; a_uses = []; a_kind = kind; a_hover = hover } in
    all := b :: !all;
    b
  in
  let make_space s_kind =
    {
      s_kind;
      s_next = 0;
      s_by_name = Hashtbl.create 16;
      s_by_index = Hashtbl.create 16;
    }
  in
  (* Register a definition in [sp] at the next index, recording its id span.
     [kind] overrides the space's kind (a function's parameters and its declared
     locals share one index space but are distinct kinds). *)
  let register ?kind sp (id : Text.name option) hover =
    let b =
      add_binding
        (Option.value kind ~default:sp.s_kind)
        (Option.map (fun (n : Text.name) -> n.info) id)
        hover
    in
    Hashtbl.replace sp.s_by_index sp.s_next b;
    sp.s_next <- sp.s_next + 1;
    (match id with
    | Some (n : Text.name) -> Hashtbl.replace sp.s_by_name n.desc b
    | None -> ());
    b
  in
  (* Record a use of index [idx] in space [sp], if it resolves. *)
  let use sp (idx : Text.idx) =
    let target =
      match idx.desc with
      | Text.Num n -> Hashtbl.find_opt sp.s_by_index (Uint32.to_int n)
      | Text.Id s -> Hashtbl.find_opt sp.s_by_name s
    in
    match target with Some b -> b.a_uses <- idx.info :: b.a_uses | None -> ()
  in

  (* The module-level index spaces. *)
  let funcs = make_space Func in
  let globals = make_space Global in
  let types = make_space Type in
  let memories = make_space Memory in
  let tables = make_space Table in
  let tags = make_space Tag in
  let elems = make_space Elem in
  let datas = make_space Data in
  (* Per struct type: its field-name space, keyed by the type's index and id. *)
  let fields_by_index : (int, space) Hashtbl.t = Hashtbl.create 16 in
  let fields_by_name : (string, space) Hashtbl.t = Hashtbl.create 16 in

  (* Type references buried in the type family (reference value types, block
     types, function-type uses). *)
  let use_heaptype (h : Text.heaptype) =
    match h with Text.Type idx | Text.Exact idx -> use types idx | _ -> ()
  in
  let use_reftype (r : Text.reftype) = use_heaptype r.Text.typ in
  let use_valtype (v : Text.valtype) =
    match v with Text.Ref r -> use_reftype r | _ -> ()
  in
  let use_typeuse ((idx_opt, ft_opt) : Text.typeuse) =
    Option.iter (use types) idx_opt;
    Option.iter
      (fun (ft : Text.functype) ->
        Array.iter (fun p -> use_valtype (snd p.desc)) ft.Text.params;
        Array.iter use_valtype ft.Text.results)
      ft_opt
  in
  let use_blocktype (b : Text.blocktype) =
    match b with
    | Text.Typeuse tu -> use_typeuse tu
    | Text.Valtype v -> use_valtype v
  in

  (* A struct-field use ([struct.get $t $f] / [struct.set $t $f]): record the
     type use, then resolve the field within that type's field space. *)
  let use_field (t : Text.idx) (fld : Text.idx) =
    use types t;
    let fsp =
      match t.desc with
      | Text.Num n -> Hashtbl.find_opt fields_by_index (Uint32.to_int n)
      | Text.Id s -> Hashtbl.find_opt fields_by_name s
    in
    Option.iter (fun sp -> use sp fld) fsp
  in

  (* Labels are lexically scoped with shadowing: [labels] is the stack of
     enclosing frames, innermost first, each carrying the label's [$id] name (for
     symbolic resolution) and its binding (for recording uses). *)
  let use_label labels (idx : Text.idx) =
    let target =
      match idx.desc with
      | Text.Num n -> List.nth_opt labels (Uint32.to_int n)
      | Text.Id s -> List.find_opt (fun (nm, _) -> nm = Some s) labels
    in
    match target with
    | Some (_, b) -> b.a_uses <- idx.info :: b.a_uses
    | None -> ()
  in
  let use_on labels (o : Text.on_clause) =
    match o with
    | Text.OnLabel (tag, l) ->
        use tags tag;
        use_label labels l
    | Text.OnSwitch tag -> use tags tag
  in

  let rec walk_instrs locals labels instrs =
    List.iter (walk_instr locals labels) instrs
  and walk_instr locals labels i =
    let open Text in
    (* Push a fresh label frame for a block-like instruction. *)
    let frame (label : name option) =
      let b =
        add_binding Label (Option.map (fun (n : name) -> n.info) label) None
      in
      (Option.map (fun (n : name) -> n.desc) label, b)
    in
    match i.desc with
    (* Structured control: a new label scope over the body. *)
    | Block { label; typ; block } | Loop { label; typ; block } ->
        Option.iter use_blocktype typ;
        walk_instrs locals (frame label :: labels) block.desc
    | If { label; typ; if_block; else_block } ->
        Option.iter use_blocktype typ;
        let ls = frame label :: labels in
        walk_instrs locals ls if_block.desc;
        walk_instrs locals ls else_block.desc
    | TryTable { label; typ; catches; block } ->
        Option.iter use_blocktype typ;
        (* Catch targets branch to the enclosing scope, not the new frame. *)
        List.iter
          (function
            | Catch (tag, l) | CatchRef (tag, l) ->
                use tags tag;
                use_label labels l
            | CatchAll l | CatchAllRef l -> use_label labels l)
          catches;
        walk_instrs locals (frame label :: labels) block.desc
    | Try { label; typ; block; catches; catch_all } ->
        Option.iter use_blocktype typ;
        let ls = frame label :: labels in
        walk_instrs locals ls block.desc;
        List.iter
          (fun (tag, body) ->
            use tags tag;
            walk_instrs locals ls body.desc)
          catches;
        Option.iter (fun body -> walk_instrs locals ls body.desc) catch_all
    | Folded (head, args) ->
        walk_instr locals labels head;
        walk_instrs locals labels args
    | Hinted (_, inner) -> walk_instr locals labels inner
    (* Branches: label uses. *)
    | Br idx | Br_if idx | Br_on_null idx | Br_on_non_null idx ->
        use_label labels idx
    | Br_table (ls, d) ->
        List.iter (use_label labels) ls;
        use_label labels d
    | Br_on_cast (l, r1, r2)
    | Br_on_cast_fail (l, r1, r2)
    | Br_on_cast_desc_eq (l, r1, r2)
    | Br_on_cast_desc_eq_fail (l, r1, r2) ->
        use_label labels l;
        use_reftype r1;
        use_reftype r2
    (* Functions. *)
    | Call idx | ReturnCall idx | RefFunc idx -> use funcs idx
    (* Globals / locals. *)
    | GlobalGet idx | GlobalSet idx -> use globals idx
    | LocalGet idx | LocalSet idx | LocalTee idx -> use locals idx
    (* Types. *)
    | CallRef idx
    | ReturnCallRef idx
    | RefGetDesc idx
    | StructNew idx
    | StructNewDefault idx
    | StructNewDesc idx
    | StructNewDefaultDesc idx
    | ArrayNew idx
    | ArrayNewDefault idx
    | ArrayNewFixed (idx, _)
    | ArrayGet (_, idx)
    | ArraySet idx
    | ArrayFill idx
    | ContNew idx ->
        use types idx
    | CallIndirect (tbl, tu) | ReturnCallIndirect (tbl, tu) ->
        use tables tbl;
        use_typeuse tu
    | ArrayCopy (a, b) ->
        use types a;
        use types b
    | ContBind (a, b) ->
        use types a;
        use types b
    | ArrayNewData (t, d) | ArrayInitData (t, d) ->
        use types t;
        use datas d
    | ArrayNewElem (t, e) | ArrayInitElem (t, e) ->
        use types t;
        use elems e
    | StructGet (_, t, fld) | StructSet (t, fld) -> use_field t fld
    (* Reference tests / casts / null. *)
    | RefTest r | RefCast r | RefCastDescEq r -> use_reftype r
    | RefNull h -> use_heaptype h
    (* Memory. *)
    | Load (idx, _, _)
    | LoadS (idx, _, _, _, _)
    | Store (idx, _, _)
    | StoreS (idx, _, _, _)
    | Atomic (idx, _, _)
    | MemorySize idx
    | MemoryGrow idx
    | MemoryFill idx
    | VecLoad (idx, _, _)
    | VecStore (idx, _)
    | VecLoadLane (idx, _, _, _)
    | VecStoreLane (idx, _, _, _)
    | VecLoadSplat (idx, _, _) ->
        use memories idx
    | MemoryCopy (a, b) ->
        use memories a;
        use memories b
    | MemoryInit (m, d) ->
        use memories m;
        use datas d
    | DataDrop idx -> use datas idx
    (* Tables. *)
    | TableGet idx
    | TableSet idx
    | TableSize idx
    | TableGrow idx
    | TableFill idx ->
        use tables idx
    | TableCopy (a, b) ->
        use tables a;
        use tables b
    | TableInit (t, e) ->
        use tables t;
        use elems e
    | ElemDrop idx -> use elems idx
    (* Tags / typed continuations. *)
    | Throw idx | Suspend idx -> use tags idx
    | Switch (ty, tag) ->
        use types ty;
        use tags tag
    | Resume (ty, ons) ->
        use types ty;
        List.iter (use_on labels) ons
    | ResumeThrow (ty, tag, ons) ->
        use types ty;
        use tags tag;
        List.iter (use_on labels) ons
    | ResumeThrowRef (ty, ons) ->
        use types ty;
        List.iter (use_on labels) ons
    (* Our extension: a string literal names the array type it builds. *)
    | String (idx_opt, _) -> Option.iter (use types) idx_opt
    | _ -> ()
  in

  (* Resolve uses in a module-scope expression (a global / elem / data / table
     initializer): no locals, no labels. *)
  let walk_const_expr expr = walk_instrs (make_space Local) [] expr in

  let use_importdesc (d : Text.importdesc) =
    match d with
    | Text.Func { typ; _ } -> use_typeuse typ
    | Text.Tag typ -> use_typeuse typ
    | Text.Global gt -> use_valtype gt.typ
    | Text.Table tt -> use_reftype tt.Text.reftype
    | Text.Memory _ -> ()
  in

  (* Pass 1: register every module-level definition (and struct fields) so that
     forward references resolve. *)
  let rec declare fields =
    List.iter
      (fun (field : (location Text.modulefield, location) annotated) ->
        match field.desc with
        | Text.Types rectype ->
            Array.iter
              (fun entry ->
                let id, sub = entry.desc in
                let tindex = types.s_next in
                ignore (register types id None);
                match sub.Text.typ with
                | Text.Struct farr -> (
                    let fsp = make_space Field in
                    Array.iter
                      (fun fe ->
                        let fid, _ = fe.desc in
                        ignore (register fsp fid None))
                      farr;
                    Hashtbl.replace fields_by_index tindex fsp;
                    match id with
                    | Some (n : Text.name) ->
                        Hashtbl.replace fields_by_name n.desc fsp
                    | None -> ())
                | _ -> ())
              rectype
        | Text.Import { id; desc; _ } -> (
            match desc with
            | Text.Func _ -> ignore (register funcs id None)
            | Text.Global _ -> ignore (register globals id None)
            | Text.Table _ -> ignore (register tables id None)
            | Text.Memory _ -> ignore (register memories id None)
            | Text.Tag _ -> ignore (register tags id None))
        | Text.Import_group1 { items; _ } ->
            List.iter
              (fun (_, id, (desc : Text.importdesc)) ->
                match desc with
                | Text.Func _ -> ignore (register funcs id None)
                | Text.Global _ -> ignore (register globals id None)
                | Text.Table _ -> ignore (register tables id None)
                | Text.Memory _ -> ignore (register memories id None)
                | Text.Tag _ -> ignore (register tags id None))
              items
        | Text.Import_group2 { desc; items; _ } ->
            let sp =
              match desc with
              | Text.Func _ -> funcs
              | Text.Global _ -> globals
              | Text.Table _ -> tables
              | Text.Memory _ -> memories
              | Text.Tag _ -> tags
            in
            List.iter (fun (_, id) -> ignore (register sp id None)) items
        | Text.Func { id; _ } -> ignore (register funcs id None)
        | Text.Global { id; _ } -> ignore (register globals id None)
        | Text.Memory { id; _ } -> ignore (register memories id None)
        | Text.Table { id; _ } -> ignore (register tables id None)
        | Text.Tag { id; _ } -> ignore (register tags id None)
        | Text.Elem { id; _ } -> ignore (register elems id None)
        | Text.Data { id; _ } -> ignore (register datas id None)
        | Text.String_global { id; _ } ->
            ignore (register globals (Some id) None)
        | Text.Module_if_annotation { then_fields; else_fields; _ } ->
            declare then_fields.desc;
            Option.iter (fun b -> declare b.desc) else_fields
        | Text.Export _ | Text.Start _ -> ())
      fields
  in

  (* Pass 2: resolve every use against the spaces built in pass 1. *)
  let rec resolve fields =
    List.iter
      (fun (field : (location Text.modulefield, location) annotated) ->
        match field.desc with
        | Text.Types rectype ->
            Array.iter
              (fun entry ->
                let _, sub = entry.desc in
                Option.iter (use types) sub.Text.supertype;
                Option.iter (use types) sub.Text.descriptor;
                Option.iter (use types) sub.Text.describes;
                match sub.Text.typ with
                | Text.Func ft ->
                    Array.iter
                      (fun p -> use_valtype (snd p.desc))
                      ft.Text.params;
                    Array.iter use_valtype ft.Text.results
                | Text.Struct farr ->
                    Array.iter
                      (fun fe ->
                        match snd fe.desc with
                        | { typ = Text.Value v; _ } -> use_valtype v
                        | _ -> ())
                      farr
                | Text.Array { typ = Text.Value v; _ } -> use_valtype v
                | Text.Array _ -> ()
                | Text.Cont idx -> use types idx)
              rectype
        | Text.Import { desc; _ } -> use_importdesc desc
        | Text.Import_group1 { items; _ } ->
            List.iter (fun (_, _, desc) -> use_importdesc desc) items
        | Text.Import_group2 { desc; _ } -> use_importdesc desc
        | Text.Func { typ; locals = decls; instrs; _ } ->
            use_typeuse typ;
            (* Parameters and declared locals share one index space but are
               distinct kinds. *)
            let locals = make_space Local in
            (match typ with
            | _, Some ft ->
                Array.iter
                  (fun p ->
                    let pid, _ = p.desc in
                    ignore (register ~kind:Param locals pid None))
                  ft.Text.params
            | _ -> ());
            List.iter
              (fun l ->
                let lid, ltyp = l.desc in
                (* Resolve the declared type's own type references, e.g.
                   [$t] in [(local $x (ref $t))]. *)
                use_valtype ltyp;
                ignore (register locals lid None))
              decls;
            walk_instrs locals [] instrs
        | Text.Global { typ; init; _ } ->
            use_valtype typ.typ;
            walk_const_expr init
        | Text.Table { typ; init; _ } -> (
            use_reftype typ.Text.reftype;
            match init with
            | Text.Init_default -> ()
            | Text.Init_expr e -> walk_const_expr e
            | Text.Init_segment es -> List.iter walk_const_expr es)
        | Text.Tag { typ; _ } -> use_typeuse typ
        | Text.Memory _ -> ()
        | Text.Elem { typ; init; mode; _ } -> (
            use_reftype typ;
            List.iter walk_const_expr init;
            match mode with
            | Text.Active (tbl, offset) ->
                use tables tbl;
                walk_const_expr offset
            | Text.Passive | Text.Declare -> ())
        | Text.Data { mode; _ } -> (
            match mode with
            | Text.Active (mem, offset) ->
                use memories mem;
                walk_const_expr offset
            | Text.Passive -> ())
        | Text.String_global { typ; _ } -> Option.iter (use types) typ
        | Text.Export { kind; index; _ } ->
            let sp =
              match kind with
              | Ast.Func -> funcs
              | Ast.Global -> globals
              | Ast.Memory -> memories
              | Ast.Table -> tables
              | Ast.Tag -> tags
            in
            use sp index
        | Text.Start idx -> use funcs idx
        | Text.Module_if_annotation { then_fields; else_fields; _ } ->
            resolve then_fields.desc;
            Option.iter (fun b -> resolve b.desc) else_fields)
      fields
  in

  declare fields;
  resolve fields;
  List.rev_map
    (fun b ->
      {
        def = b.a_def;
        uses = List.rev b.a_uses;
        kind = b.a_kind;
        hover = b.a_hover;
      })
    !all
