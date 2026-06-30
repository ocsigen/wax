open Ast
module T = Text
module B = Binary
module StringMap = Map.Make (String)

exception Conditional_in_binary of location

(* Raised when a named index or label reference resolves to nothing. Carries the
   reference's location and a message describing what could not be resolved, so
   the caller can report a located diagnostic rather than crash. *)
exception Unresolved_reference of location * string

type index_space = { map : B.idx StringMap.t; count : int }

let empty_space = { map = StringMap.empty; count = 0 }

let add_name space id =
  let idx = space.count in
  let map =
    match id with
    | Some name -> StringMap.add name.Ast.desc idx space.map
    | None -> space.map
  in
  ({ map; count = idx + 1 }, idx)

type context = {
  funcs : index_space;
  globals : index_space;
  tables : index_space;
  memories : index_space;
  types : index_space;
  fields : int StringMap.t B.IntMap.t;
  tags : index_space;
  datas : index_space;
  elems : index_space;
  (* Label stack for current function *)
  labels : string option list;
  (* Locals for current function *)
  locals : index_space;
}

let empty_context =
  {
    funcs = empty_space;
    globals = empty_space;
    tables = empty_space;
    memories = empty_space;
    types = empty_space;
    fields = B.IntMap.empty;
    tags = empty_space;
    datas = empty_space;
    elems = empty_space;
    labels = [];
    locals = empty_space;
  }

let resolve_idx space (idx : T.idx) : B.idx =
  match idx.desc with
  | T.Num n -> Wax_utils.Uint32.to_int n
  | T.Id id -> (
      match StringMap.find_opt id space.map with
      | Some i -> i
      | None ->
          raise
            (Unresolved_reference (idx.info, "Unknown identifier $" ^ id ^ "."))
      )

let resolve_label labels (idx : T.idx) : B.idx =
  match idx.desc with
  | T.Num n -> Wax_utils.Uint32.to_int n
  | T.Id id ->
      let rec find_depth stack depth =
        match stack with
        | [] ->
            raise
              (Unresolved_reference (idx.info, "Unknown label $" ^ id ^ "."))
        | Some name :: rest ->
            if name = id then depth else find_depth rest (depth + 1)
        | None :: rest -> find_depth rest (depth + 1)
      in
      find_depth labels 0

(* Conversion functions *)

let heaptype ctx (h : T.heaptype) : B.heaptype =
  match h with
  | Func -> Func
  | NoFunc -> NoFunc
  | Exn -> Exn
  | NoExn -> NoExn
  | Cont -> Cont
  | NoCont -> NoCont
  | Extern -> Extern
  | NoExtern -> NoExtern
  | Any -> Any
  | Eq -> Eq
  | I31 -> I31
  | Struct -> Struct
  | Array -> Array
  | None_ -> None_
  | Type i -> Type (resolve_idx ctx.types i)

let reftype ctx (r : T.reftype) : B.reftype =
  { nullable = r.nullable; typ = heaptype ctx r.typ }

let valtype ctx (v : T.valtype) : B.valtype =
  match v with
  | I32 -> I32
  | I64 -> I64
  | F32 -> F32
  | F64 -> F64
  | V128 -> V128
  | Ref r -> Ref (reftype ctx r)

let storage_type ctx (s : T.storagetype) : B.storagetype =
  match s with Value v -> Value (valtype ctx v) | Packed p -> Packed p

let mut_type typ_f ctx m = { mut = m.mut; typ = typ_f ctx m.typ }
let field_type ctx f = mut_type storage_type ctx f

let func_type ctx (f : T.functype) : B.functype =
  {
    params = Array.map (fun p -> valtype ctx (snd p.Ast.desc)) f.params;
    results = Array.map (valtype ctx) f.results;
  }

let comp_type ctx (c : T.comptype) : B.comptype =
  match c with
  | Func f -> Func (func_type ctx f)
  | Struct f -> Struct (Array.map (fun e -> field_type ctx (snd e.Ast.desc)) f)
  | Array f -> Array (field_type ctx f)
  | Cont i -> Cont (resolve_idx ctx.types i)

let sub_type ctx (s : T.subtype) : B.subtype =
  {
    typ = comp_type ctx s.typ;
    supertype = Option.map (resolve_idx ctx.types) s.supertype;
    final = s.final;
  }

let rec_type ctx r = Array.map (fun e -> sub_type ctx (snd e.Ast.desc)) r
let global_type ctx g = mut_type valtype ctx g

let table_type ctx (t : T.tabletype) : B.tabletype =
  { limits = t.limits.desc; reftype = reftype ctx t.reftype }

let block_type ~resolve_func_type ctx (b : T.blocktype) : B.blocktype =
  match b with
  | Typeuse (Some i, _) -> Typeuse (resolve_idx ctx.types i)
  | Typeuse (None, Some ft) -> Typeuse (resolve_func_type ctx ft)
  | Typeuse (None, None) -> assert false
  | Valtype v -> Valtype (valtype ctx v)

let catch ctx (c : T.catch) : B.catch =
  match c with
  | Catch (tag, label) ->
      Catch (resolve_idx ctx.tags tag, resolve_label ctx.labels label)
  | CatchRef (tag, label) ->
      CatchRef (resolve_idx ctx.tags tag, resolve_label ctx.labels label)
  | CatchAll label -> CatchAll (resolve_label ctx.labels label)
  | CatchAllRef label -> CatchAllRef (resolve_label ctx.labels label)

let on_clause ctx (c : T.on_clause) : B.on_clause =
  match c with
  | OnLabel (tag, label) ->
      OnLabel (resolve_idx ctx.tags tag, resolve_label ctx.labels label)
  | OnSwitch tag -> OnSwitch (resolve_idx ctx.tags tag)

let resolve_field_idx ctx type_idx (field_idx_text : T.idx) : B.idx =
  match field_idx_text.desc with
  | T.Num n -> Wax_utils.Uint32.to_int n
  | T.Id id -> (
      match B.IntMap.find_opt type_idx ctx.fields with
      | Some field_map -> (
          match StringMap.find_opt id field_map with
          | Some f_idx -> f_idx
          | None ->
              raise
                (Unresolved_reference
                   (field_idx_text.info, "Unknown field $" ^ id ^ ".")))
      | None ->
          raise
            (Unresolved_reference
               (field_idx_text.info, "Unknown field $" ^ id ^ ".")))

let push_label ctx label =
  { ctx with labels = Option.map (fun l -> l.Ast.desc) label :: ctx.labels }

let string i ty s =
  let s = String.concat "" (List.map (fun s -> s.Ast.desc) s) in
  B.Folded
    ( { i with desc = ArrayNewFixed (ty, Uint32.of_int (String.length s)) },
      String.fold_right
        (fun c acc ->
          { i with desc = B.Const (I32 (Int32.of_int (Char.code c))) } :: acc)
        s [] )

let rec instr ~resolve_string_type ~resolve_func_type ctx (i : 'info T.instr) =
  let desc : _ B.instr_desc =
    match i.desc with
    | Block { label; typ; block } ->
        let ctx' = push_label ctx label in
        Block
          {
            label = ();
            typ = Option.map (block_type ~resolve_func_type ctx) typ;
            block =
              List.map
                (instr ~resolve_string_type ~resolve_func_type ctx')
                block;
          }
    | Loop { label; typ; block } ->
        let ctx' = push_label ctx label in
        Loop
          {
            label = ();
            typ = Option.map (block_type ~resolve_func_type ctx) typ;
            block =
              List.map
                (instr ~resolve_string_type ~resolve_func_type ctx')
                block;
          }
    | If { label; typ; if_block; else_block } ->
        let ctx' = push_label ctx label in
        If
          {
            label = ();
            typ = Option.map (block_type ~resolve_func_type ctx) typ;
            if_block =
              Ast.no_loc
                (List.map
                   (instr ~resolve_string_type ~resolve_func_type ctx')
                   if_block.desc);
            else_block =
              Ast.no_loc
                (List.map
                   (instr ~resolve_string_type ~resolve_func_type ctx')
                   else_block.desc);
          }
    | Unreachable -> Unreachable
    | Nop -> Nop
    | Br i -> Br (resolve_label ctx.labels i)
    | Br_if i -> Br_if (resolve_label ctx.labels i)
    | Br_table (ls, d) ->
        Br_table
          (List.map (resolve_label ctx.labels) ls, resolve_label ctx.labels d)
    | Return -> Return
    | Call i -> Call (resolve_idx ctx.funcs i)
    | ReturnCall i -> ReturnCall (resolve_idx ctx.funcs i)
    | CallIndirect (table, (idx_opt, type_opt)) ->
        let type_idx =
          match idx_opt with
          | Some i -> resolve_idx ctx.types i
          | None -> (
              match type_opt with
              | Some ft -> resolve_func_type ctx ft
              | None -> assert false)
        in
        CallIndirect (resolve_idx ctx.tables table, type_idx)
    | ReturnCallIndirect (table, (idx_opt, type_opt)) ->
        let type_idx =
          match idx_opt with
          | Some i -> resolve_idx ctx.types i
          | None -> (
              match type_opt with
              | Some ft -> resolve_func_type ctx ft
              | None -> assert false)
        in
        ReturnCallIndirect (resolve_idx ctx.tables table, type_idx)
    | Drop -> Drop
    | Select None -> Select None
    | Select (Some l) -> Select (Some (List.map (valtype ctx) l))
    | LocalGet i -> LocalGet (resolve_idx ctx.locals i)
    | LocalSet i -> LocalSet (resolve_idx ctx.locals i)
    | LocalTee i -> LocalTee (resolve_idx ctx.locals i)
    | GlobalGet i -> GlobalGet (resolve_idx ctx.globals i)
    | GlobalSet i -> GlobalSet (resolve_idx ctx.globals i)
    | Load (o, m, op) -> Load (resolve_idx ctx.memories o, m, op)
    | Store (o, m, op) -> Store (resolve_idx ctx.memories o, m, op)
    | LoadS (o, m, sz, bt, s) -> LoadS (resolve_idx ctx.memories o, m, sz, bt, s)
    | StoreS (o, m, sz, bt) -> StoreS (resolve_idx ctx.memories o, m, sz, bt)
    | MemorySize i -> MemorySize (resolve_idx ctx.memories i)
    | MemoryGrow i -> MemoryGrow (resolve_idx ctx.memories i)
    | MemoryFill i -> MemoryFill (resolve_idx ctx.memories i)
    | MemoryCopy (i1, i2) ->
        MemoryCopy (resolve_idx ctx.memories i1, resolve_idx ctx.memories i2)
    | MemoryInit (i1, i2) ->
        (* Text order is (memory, data); binary order is (data, memory). *)
        let mem = resolve_idx ctx.memories i1 in
        let data = resolve_idx ctx.datas i2 in
        MemoryInit (data, mem)
    | DataDrop i -> DataDrop (resolve_idx ctx.datas i)
    | TableGet i -> TableGet (resolve_idx ctx.tables i)
    | TableSet i -> TableSet (resolve_idx ctx.tables i)
    | TableSize i -> TableSize (resolve_idx ctx.tables i)
    | TableGrow i -> TableGrow (resolve_idx ctx.tables i)
    | TableFill i -> TableFill (resolve_idx ctx.tables i)
    | TableCopy (i1, i2) ->
        TableCopy (resolve_idx ctx.tables i1, resolve_idx ctx.tables i2)
    | TableInit (i1, i2) ->
        (* Text order is (table, elem); binary order is (elem, table). *)
        let table = resolve_idx ctx.tables i1 in
        let elem = resolve_idx ctx.elems i2 in
        TableInit (elem, table)
    | ElemDrop i -> ElemDrop (resolve_idx ctx.elems i)
    | Const (I32 x) -> Const (I32 (Wax_utils.Number_parsing.int32 x))
    | Const (I64 x) -> Const (I64 (Wax_utils.Number_parsing.int64 x))
    | Const (F32 x) -> Const (F32 (Wax_utils.Number_parsing.float32 x))
    | Const (F64 x) -> Const (F64 (Wax_utils.Number_parsing.float64 x))
    | UnOp op -> UnOp op
    | BinOp op -> BinOp op
    | RefNull t -> RefNull (heaptype ctx t)
    | RefFunc i -> RefFunc (resolve_idx ctx.funcs i)
    | RefIsNull -> RefIsNull
    | TryTable { label; typ; catches; block } ->
        let ctx' = push_label ctx label in
        TryTable
          {
            label = ();
            typ = Option.map (block_type ~resolve_func_type ctx) typ;
            catches = List.map (catch ctx) catches;
            block =
              List.map
                (instr ~resolve_string_type ~resolve_func_type ctx')
                block;
          }
    | Try { label; typ; block; catches; catch_all } ->
        let ctx' = push_label ctx label in
        Try
          {
            label = ();
            typ = Option.map (block_type ~resolve_func_type ctx) typ;
            block =
              List.map
                (instr ~resolve_string_type ~resolve_func_type ctx')
                block;
            catches =
              List.map
                (fun (tag, b) ->
                  ( resolve_idx ctx.tags tag,
                    List.map
                      (instr ~resolve_string_type ~resolve_func_type ctx')
                      b ))
                catches;
            catch_all =
              Option.map
                (List.map (instr ~resolve_string_type ~resolve_func_type ctx'))
                catch_all;
          }
    | Throw i -> Throw (resolve_idx ctx.tags i)
    | ThrowRef -> ThrowRef
    | ContNew i -> ContNew (resolve_idx ctx.types i)
    | ContBind (i, j) ->
        ContBind (resolve_idx ctx.types i, resolve_idx ctx.types j)
    | Suspend i -> Suspend (resolve_idx ctx.tags i)
    | Resume (i, clauses) ->
        Resume (resolve_idx ctx.types i, List.map (on_clause ctx) clauses)
    | ResumeThrow (i, j, clauses) ->
        ResumeThrow
          ( resolve_idx ctx.types i,
            resolve_idx ctx.tags j,
            List.map (on_clause ctx) clauses )
    | ResumeThrowRef (i, clauses) ->
        ResumeThrowRef
          (resolve_idx ctx.types i, List.map (on_clause ctx) clauses)
    | Switch (i, j) -> Switch (resolve_idx ctx.types i, resolve_idx ctx.tags j)
    | Br_on_null i -> Br_on_null (resolve_label ctx.labels i)
    | Br_on_non_null i -> Br_on_non_null (resolve_label ctx.labels i)
    | Br_on_cast (i, r1, r2) ->
        Br_on_cast (resolve_label ctx.labels i, reftype ctx r1, reftype ctx r2)
    | Br_on_cast_fail (i, r1, r2) ->
        Br_on_cast_fail
          (resolve_label ctx.labels i, reftype ctx r1, reftype ctx r2)
    | CallRef i -> CallRef (resolve_idx ctx.types i)
    | ReturnCallRef i -> ReturnCallRef (resolve_idx ctx.types i)
    | RefAsNonNull -> RefAsNonNull
    | RefEq -> RefEq
    | RefTest r -> RefTest (reftype ctx r)
    | RefCast r -> RefCast (reftype ctx r)
    | StructNew i -> StructNew (resolve_idx ctx.types i)
    | StructNewDefault i -> StructNewDefault (resolve_idx ctx.types i)
    | StructGet (s, i1, i2) ->
        let type_idx = resolve_idx ctx.types i1 in
        StructGet (s, type_idx, resolve_field_idx ctx type_idx i2)
    | StructSet (i1, i2) ->
        let type_idx = resolve_idx ctx.types i1 in
        StructSet (type_idx, resolve_field_idx ctx type_idx i2)
    | ArrayNew i -> ArrayNew (resolve_idx ctx.types i)
    | ArrayNewDefault i -> ArrayNewDefault (resolve_idx ctx.types i)
    | ArrayNewFixed (i, u) -> ArrayNewFixed (resolve_idx ctx.types i, u)
    | ArrayNewData (i1, i2) ->
        ArrayNewData (resolve_idx ctx.types i1, resolve_idx ctx.datas i2)
    | ArrayNewElem (i1, i2) ->
        ArrayNewElem (resolve_idx ctx.types i1, resolve_idx ctx.elems i2)
    | ArrayGet (s, i) -> ArrayGet (s, resolve_idx ctx.types i)
    | ArraySet i -> ArraySet (resolve_idx ctx.types i)
    | ArrayLen -> ArrayLen
    | ArrayFill i -> ArrayFill (resolve_idx ctx.types i)
    | ArrayCopy (i1, i2) ->
        ArrayCopy (resolve_idx ctx.types i1, resolve_idx ctx.types i2)
    | ArrayInitData (i1, i2) ->
        ArrayInitData (resolve_idx ctx.types i1, resolve_idx ctx.datas i2)
    | ArrayInitElem (i1, i2) ->
        ArrayInitElem (resolve_idx ctx.types i1, resolve_idx ctx.elems i2)
    | RefI31 -> RefI31
    | I31Get s -> I31Get s
    | I32WrapI64 -> I32WrapI64
    | I64ExtendI32 s -> I64ExtendI32 s
    | F32DemoteF64 -> F32DemoteF64
    | F64PromoteF32 -> F64PromoteF32
    | ExternConvertAny -> ExternConvertAny
    | AnyConvertExtern -> AnyConvertExtern
    | VecLoad (o, op, m) -> VecLoad (resolve_idx ctx.memories o, op, m)
    | VecStore (o, m) -> VecStore (resolve_idx ctx.memories o, m)
    | VecLoadLane (o, op, m, lane) ->
        VecLoadLane (resolve_idx ctx.memories o, op, m, lane)
    | VecStoreLane (o, op, m, lane) ->
        VecStoreLane (resolve_idx ctx.memories o, op, m, lane)
    | VecLoadSplat (o, op, m) -> VecLoadSplat (resolve_idx ctx.memories o, op, m)
    | VecConst v -> VecConst (Wax_utils.V128.to_string v)
    | VecUnOp op -> VecUnOp op
    | VecBinOp op -> VecBinOp op
    | VecTest op -> VecTest op
    | VecShift op -> VecShift op
    | VecBitmask op -> VecBitmask op
    | VecBitselect -> VecBitselect
    | VecExtract (op, signage, lane) -> VecExtract (op, signage, lane)
    | VecReplace (op, lane) -> VecReplace (op, lane)
    | VecSplat op -> VecSplat op
    | VecShuffle v -> VecShuffle v
    | VecTernOp op -> VecTernOp op
    | String (idx, s) ->
        let ty =
          match idx with
          | None -> resolve_string_type ()
          | Some id -> resolve_idx ctx.types id
        in
        string i ty s
    | Char c -> Const (I32 (Int32.of_int (Uchar.to_int c)))
    | If_annotation _ -> raise (Conditional_in_binary i.info)
    | Folded (i, is) ->
        Folded
          ( instr ~resolve_string_type ~resolve_func_type ctx i,
            List.map (instr ~resolve_string_type ~resolve_func_type ctx) is )
  in
  { desc; info = i.info }

let collect_labels instrs ctr map =
  let add ctr map label =
    let idx = !ctr in
    incr ctr;
    match label with Some l -> B.IntMap.add idx l.desc map | None -> map
  in
  let rec go instrs ctr map =
    List.fold_left
      (fun map (i : _ T.instr) ->
        match i.desc with
        | Block { label; block; _ } | Loop { label; block; _ } ->
            add ctr map label |> go block ctr
        | If { label; if_block; else_block; _ } ->
            add ctr map label |> go if_block.desc ctr |> go else_block.desc ctr
        | TryTable { label; block; _ } -> add ctr map label |> go block ctr
        | Try { label; block; catches; catch_all; _ } -> (
            let map = add ctr map label |> go block ctr in
            let map =
              List.fold_left (fun map (_, b) -> go b ctr map) map catches
            in
            match catch_all with Some b -> go b ctr map | None -> map)
        | _ -> map)
      map instrs
  in
  go instrs ctr map

let invert_map map =
  StringMap.fold (fun k v acc -> B.IntMap.add v k acc) map B.IntMap.empty

let module_ (m : 'info T.module_) : 'info B.module_ =
  Wax_utils.Debug.timed "to-binary" @@ fun () ->
  let module_name, fields = m in

  (* Pass 1: Build Context *)
  let ctx = empty_context in

  let func_types_by_idx = B.IntMap.empty in
  let ctx, func_types_by_idx =
    List.fold_left
      (fun (ctx, acc_func_types) f ->
        match f.desc with
        | T.Types r ->
            let types_space, _ =
              Array.fold_left
                (fun (space, _) e -> add_name space (fst e.Ast.desc))
                (ctx.types, 0) r
            in
            let current_type_idx = ctx.types.count in
            let acc_func_types =
              let ctx' = { ctx with types = types_space } in
              Array.fold_left
                (fun (acc_map, idx_in_arr) e ->
                  let subtype = snd e.Ast.desc in
                  match subtype.T.typ with
                  | T.Func func_t ->
                      let b_func_t = func_type ctx' func_t in
                      ( B.IntMap.add
                          (current_type_idx + idx_in_arr)
                          (Array.length b_func_t.B.Types.params)
                          acc_map,
                        idx_in_arr + 1 )
                  | _ -> (acc_map, idx_in_arr + 1))
                (acc_func_types, 0) r
              |> fst
            in
            ({ ctx with types = types_space }, acc_func_types)
        | T.Import { id; desc; _ } -> (
            match desc with
            | T.Func _ ->
                ( { ctx with funcs = fst (add_name ctx.funcs id) },
                  acc_func_types )
            | T.Table _ ->
                ( { ctx with tables = fst (add_name ctx.tables id) },
                  acc_func_types )
            | T.Memory _ ->
                ( { ctx with memories = fst (add_name ctx.memories id) },
                  acc_func_types )
            | T.Global _ ->
                ( { ctx with globals = fst (add_name ctx.globals id) },
                  acc_func_types )
            | T.Tag _ ->
                ({ ctx with tags = fst (add_name ctx.tags id) }, acc_func_types)
            )
        | T.Func { id; _ } ->
            ({ ctx with funcs = fst (add_name ctx.funcs id) }, acc_func_types)
        | T.Table { id; _ } ->
            ({ ctx with tables = fst (add_name ctx.tables id) }, acc_func_types)
        | T.Memory { id; _ } ->
            ( { ctx with memories = fst (add_name ctx.memories id) },
              acc_func_types )
        | T.Global { id; _ } ->
            ( { ctx with globals = fst (add_name ctx.globals id) },
              acc_func_types )
        | T.Tag { id; _ } ->
            ({ ctx with tags = fst (add_name ctx.tags id) }, acc_func_types)
        | T.Elem { id; _ } ->
            ({ ctx with elems = fst (add_name ctx.elems id) }, acc_func_types)
        | T.Data { id; _ } ->
            ({ ctx with datas = fst (add_name ctx.datas id) }, acc_func_types)
        | T.String_global { id; _ } ->
            ( { ctx with globals = fst (add_name ctx.globals (Some id)) },
              acc_func_types )
        | T.Module_if_annotation _ -> raise (Conditional_in_binary f.Ast.info)
        | T.Start _ | T.Export _ -> (ctx, acc_func_types))
      (ctx, func_types_by_idx) fields
  in

  (* Collect Struct Field Names *)
  let field_names =
    let rec scan_fields type_idx fields acc =
      match fields with
      | [] -> acc
      | { desc = T.Types r; _ } :: rest ->
          let acc, _ =
            Array.fold_left
              (fun (acc, i) e ->
                match (snd e.Ast.desc).T.typ with
                | T.Struct field_defs ->
                    let field_map =
                      Array.fold_left
                        (fun (fmap, fidx) e ->
                          match fst e.Ast.desc with
                          | Some n ->
                              (StringMap.add n.Ast.desc fidx fmap, fidx + 1)
                          | None -> (fmap, fidx + 1))
                        (StringMap.empty, 0) field_defs
                      |> fst
                    in
                    if StringMap.is_empty field_map then (acc, i + 1)
                    else (B.IntMap.add (type_idx + i) field_map acc, i + 1)
                | _ -> (acc, i + 1))
              (acc, 0) r
          in
          scan_fields (type_idx + Array.length r) rest acc
      | _ :: rest -> scan_fields type_idx rest acc
    in
    scan_fields 0 fields B.IntMap.empty
  in
  let ctx = { ctx with fields = field_names } in

  (* Type Memoization *)
  let type_map = Hashtbl.create 1024 in
  let string_type = ref None in
  let extra_types = ref [] in
  let type_count = ref ctx.types.count in
  (* Number of parameters of each implicit function type, keyed by its index.
     [func_types_by_idx] below only covers explicitly-defined types; this
     records the implicit ones appended for inline signatures so that a
     function declared as [(func (type N))] referring to such a type can still
     determine how many (unnamed) parameters precede its locals. *)
  let impl_func_params = ref B.IntMap.empty in

  (* Populate type_map with existing explicit types *)
  let () =
    let rec scan_existing_types idx fields =
      match fields with
      | [] -> ()
      | {
          desc =
            T.Types
              [|
                {
                  Ast.desc =
                    _, { final = true; supertype = None; typ = T.Func f };
                  _;
                };
              |];
          _;
        }
        :: rest ->
          (let b_f = func_type ctx f in
           if not (Hashtbl.mem type_map b_f) then Hashtbl.add type_map b_f idx);
          scan_existing_types (idx + 1) rest
      | {
          desc =
            T.Types
              [|
                {
                  Ast.desc =
                    ( _,
                      {
                        final = true;
                        supertype = None;
                        typ = T.Array { mut = true; typ = Packed I8 };
                      } );
                  _;
                };
              |];
          _;
        }
        :: rest ->
          string_type := Some idx;
          scan_existing_types (idx + 1) rest
      | { desc = T.Types r; _ } :: rest ->
          scan_existing_types (idx + Array.length r) rest
      | _ :: rest -> scan_existing_types idx rest
    in
    scan_existing_types 0 fields
  in

  let resolve_string_type () =
    match !string_type with
    | Some i -> i
    | None ->
        let i = !type_count in
        type_count := i + 1;
        string_type := Some i;
        extra_types := B.Array { mut = true; typ = Packed I8 } :: !extra_types;
        i
  in

  let resolve_func_type ctx (ft : T.functype) : int =
    let ft = func_type ctx ft in
    match Hashtbl.find_opt type_map ft with
    | Some i -> i
    | None ->
        let i = !type_count in
        type_count := i + 1;
        Hashtbl.add type_map ft i;
        extra_types := B.Func ft :: !extra_types;
        impl_func_params :=
          B.IntMap.add i (Array.length ft.B.Types.params) !impl_func_params;
        i
  in

  (* Pass 2: Convert *)
  let imports =
    List.filter_map
      (fun f ->
        match f.desc with
        | T.Import { module_; name; desc; _ } ->
            let desc : B.importdesc =
              match desc with
              | Func (Some i, _) -> Func (resolve_idx ctx.types i)
              | Func (None, Some ty) -> Func (resolve_func_type ctx ty)
              | Func (None, None) -> assert false
              | Table t -> Table (table_type ctx t)
              | Memory l -> Memory l.desc
              | Global g -> Global (global_type ctx g)
              | Tag (Some i, _) -> Tag (resolve_idx ctx.types i)
              | Tag (None, Some ty) -> Tag (resolve_func_type ctx ty)
              | Tag (None, None) -> failwith "Tag import missing type"
            in
            Some { B.module_ = module_.desc; name = name.desc; desc }
        | _ -> None)
      fields
  in

  let explicit_types =
    List.filter_map
      (fun f ->
        match f.desc with T.Types r -> Some (rec_type ctx r) | _ -> None)
      fields
  in

  let functions =
    List.filter_map
      (fun f ->
        match f.desc with
        | T.Func { typ; _ } -> (
            match typ with
            | Some i, _ -> Some (resolve_idx ctx.types i)
            | None, Some ty -> Some (resolve_func_type ctx ty)
            | None, None -> assert false)
        | _ -> None)
      fields
  in

  (* Prepare for Code Generation: Calculate Import Count for Indexing *)
  let func_import_count =
    List.fold_left
      (fun acc f ->
        match f.desc with
        | T.Import { desc = T.Func _; _ } -> acc + 1
        | _ -> acc)
      0 fields
  in

  let locals_names = ref B.IntMap.empty in
  let labels_names = ref B.IntMap.empty in

  let code =
    let rec process_funcs func_types_by_idx fields func_idx acc =
      match fields with
      | [] -> List.rev acc
      | { desc = T.Func { typ; locals; instrs; _ }; _ } :: rest ->
          (* Build local context *)
          let locals_space =
            let num_unnamed_params =
              match typ with
              | Some type_idx, None -> (
                  let resolved_idx = resolve_idx ctx.types type_idx in
                  match B.IntMap.find_opt resolved_idx func_types_by_idx with
                  | Some num_params -> num_params
                  | None -> (
                      match
                        B.IntMap.find_opt resolved_idx !impl_func_params
                      with
                      | Some num_params -> num_params
                      | None -> assert false))
              | _ -> 0
            in
            let all_ids =
              (match typ with
                | _, Some { params; _ } ->
                    Array.to_list (Array.map (fun p -> fst p.Ast.desc) params)
                | _, None -> [])
              @ List.map (fun e -> fst e.Ast.desc) locals
            in
            List.fold_left
              (fun space id -> fst (add_name space id))
              { empty_space with count = num_unnamed_params }
              all_ids
          in
          let func_ctx = { ctx with locals = locals_space } in

          (* Collect Local Names *)
          let local_map = invert_map locals_space.map in
          if not (B.IntMap.is_empty local_map) then
            locals_names := B.IntMap.add func_idx local_map !locals_names;

          (* Collect Label Names *)
          let label_map = collect_labels instrs (ref 0) B.IntMap.empty in
          if not (B.IntMap.is_empty label_map) then
            labels_names := B.IntMap.add func_idx label_map !labels_names;

          let b_locals =
            List.map (fun e -> valtype ctx (snd e.Ast.desc)) locals
          in
          let converted_func =
            {
              B.locals = b_locals;
              instrs =
                List.map
                  (instr ~resolve_string_type ~resolve_func_type func_ctx)
                  instrs;
            }
          in

          process_funcs func_types_by_idx rest (func_idx + 1)
            (converted_func :: acc)
      | _ :: rest -> process_funcs func_types_by_idx rest func_idx acc
    in
    process_funcs func_types_by_idx fields func_import_count []
  in

  let tables =
    List.filter_map
      (fun f ->
        match f.desc with
        | T.Table { typ; init; _ } ->
            let expr =
              match init with
              | T.Init_expr e ->
                  Some
                    (List.map
                       (instr ~resolve_string_type ~resolve_func_type ctx)
                       e)
              | _ -> None
            in
            Some { B.typ = table_type ctx typ; B.expr }
        | _ -> None)
      fields
  in

  let memories =
    List.filter_map
      (fun f ->
        match f.desc with
        | T.Memory { limits; _ } -> Some limits.desc
        | _ -> None)
      fields
  in

  let globals =
    List.filter_map
      (fun f ->
        match f.desc with
        | T.Global { typ; init; _ } ->
            Some
              {
                B.typ = global_type ctx typ;
                B.init =
                  List.map
                    (instr ~resolve_string_type ~resolve_func_type ctx)
                    init;
              }
        | T.String_global { init; _ } ->
            let ty = resolve_string_type () in
            Some
              {
                B.typ =
                  { mut = false; typ = Ref { nullable = false; typ = Type ty } };
                B.init = [ { f with desc = string f ty init } ];
              }
        | _ -> None)
      fields
  in

  (* Collect Exports *)
  let exports =
    let rec scan fields funcs tables memories globals tags acc =
      match fields with
      | [] -> List.rev acc
      | f :: rest ->
          let acc =
            match f.desc with
            | T.Export { name; kind; index } ->
                let kind, index =
                  match kind with
                  | Func -> (Ast.Func, resolve_idx ctx.funcs index)
                  | Table -> (Ast.Table, resolve_idx ctx.tables index)
                  | Memory -> (Ast.Memory, resolve_idx ctx.memories index)
                  | Global -> (Ast.Global, resolve_idx ctx.globals index)
                  | Tag -> (Ast.Tag, resolve_idx ctx.tags index)
                in
                { B.name = name.desc; kind; index } :: acc
            | T.Func { exports; _ } ->
                let f (e : T.name) =
                  { B.name = e.desc; kind = Ast.Func; index = funcs }
                in
                List.rev_map f exports @ acc
            | T.Table { exports; _ } ->
                let f (e : T.name) =
                  { B.name = e.desc; kind = Ast.Table; index = tables }
                in
                List.rev_map f exports @ acc
            | T.Memory { exports; _ } ->
                let f (e : T.name) =
                  { B.name = e.desc; kind = Ast.Memory; index = memories }
                in
                List.rev_map f exports @ acc
            | T.Global { exports; _ } ->
                let f (e : T.name) =
                  { B.name = e.desc; kind = Ast.Global; index = globals }
                in
                List.rev_map f exports @ acc
            | T.Tag { exports; _ } ->
                let f (e : T.name) =
                  { B.name = e.desc; kind = Ast.Tag; index = tags }
                in
                List.rev_map f exports @ acc
            | T.Import { desc; exports; _ } ->
                let kind, index =
                  match desc with
                  | T.Func _ -> (Ast.Func, funcs)
                  | T.Table _ -> (Ast.Table, tables)
                  | T.Memory _ -> (Ast.Memory, memories)
                  | T.Global _ -> (Ast.Global, globals)
                  | T.Tag _ -> (Ast.Tag, tags)
                in
                let f (e : T.name) = { B.name = e.desc; kind; index } in
                List.rev_map f exports @ acc
            | _ -> acc
          in
          let funcs, tables, memories, globals, tags =
            match f.desc with
            | T.Func _ -> (funcs + 1, tables, memories, globals, tags)
            | T.Table _ -> (funcs, tables + 1, memories, globals, tags)
            | T.Memory _ -> (funcs, tables, memories + 1, globals, tags)
            | T.Global _ -> (funcs, tables, memories, globals + 1, tags)
            (* [String_global] ([(@string ...)]) also occupies a global index,
               so it must advance the global counter; otherwise an inline global
               export following one resolves to too low an index. *)
            | T.String_global _ -> (funcs, tables, memories, globals + 1, tags)
            | T.Tag _ -> (funcs, tables, memories, globals, tags + 1)
            | T.Import { desc; _ } -> (
                match desc with
                | T.Func _ -> (funcs + 1, tables, memories, globals, tags)
                | T.Table _ -> (funcs, tables + 1, memories, globals, tags)
                | T.Memory _ -> (funcs, tables, memories + 1, globals, tags)
                | T.Global _ -> (funcs, tables, memories, globals + 1, tags)
                | T.Tag _ -> (funcs, tables, memories, globals, tags + 1))
            | _ -> (funcs, tables, memories, globals, tags)
          in
          scan rest funcs tables memories globals tags acc
    in
    scan fields 0 0 0 0 0 []
  in

  let start =
    List.find_map
      (fun f ->
        match f.desc with
        | T.Start i -> Some (resolve_idx ctx.funcs i)
        | _ -> None)
      fields
  in

  let table_import_count =
    List.fold_left
      (fun acc f ->
        match f.desc with
        | T.Import { desc = T.Table _; _ } -> acc + 1
        | _ -> acc)
      0 fields
  in

  let elem =
    let rec scan fields table_idx acc =
      match fields with
      | [] -> List.rev acc
      | { desc = T.Elem { typ; init; mode; _ }; _ } :: rest ->
          let mode : 'info B.elemmode =
            match mode with
            | Passive -> Passive
            | Active (i, ex) ->
                Active
                  ( resolve_idx ctx.tables i,
                    List.map
                      (instr ~resolve_string_type ~resolve_func_type ctx)
                      ex )
            | Declare -> Declare
          in
          let e =
            {
              B.typ = reftype ctx typ;
              init =
                List.map
                  (List.map (instr ~resolve_string_type ~resolve_func_type ctx))
                  init;
              mode;
            }
          in
          scan rest table_idx (e :: acc)
      | { desc = T.Table { typ; init = T.Init_segment exprs; _ }; _ } :: rest ->
          let mode =
            B.Active
              ( table_idx,
                [
                  Ast.no_loc
                    (B.Const
                       (match typ.limits.desc.address_type with
                       | `I32 -> B.I32 0l
                       | `I64 -> B.I64 0L));
                ] )
          in
          let e =
            {
              B.typ = reftype ctx typ.reftype;
              init =
                List.map
                  (List.map (instr ~resolve_string_type ~resolve_func_type ctx))
                  exprs;
              mode;
            }
          in
          scan rest (table_idx + 1) (e :: acc)
      | { desc = T.Table _; _ } :: rest -> scan rest (table_idx + 1) acc
      | _ :: rest -> scan rest table_idx acc
    in
    scan fields table_import_count []
  in

  let memory_import_count =
    List.fold_left
      (fun acc f ->
        match f.desc with
        | T.Import { desc = T.Memory _; _ } -> acc + 1
        | _ -> acc)
      0 fields
  in

  let data =
    let rec scan fields mem_idx acc =
      match fields with
      | [] -> List.rev acc
      | { desc = T.Data { init; mode; _ }; _ } :: rest ->
          let mode : 'info B.datamode =
            match mode with
            | Passive -> Passive
            | Active (i, ex) ->
                Active
                  ( resolve_idx ctx.memories i,
                    List.map
                      (instr ~resolve_string_type ~resolve_func_type ctx)
                      ex )
          in
          let init = String.concat "" (List.map (fun s -> s.Ast.desc) init) in
          let d = { B.init; mode } in
          scan rest mem_idx (d :: acc)
      | { desc = T.Memory { init = Some init; limits; _ }; _ } :: rest ->
          let (mode : 'info B.datamode) =
            B.Active
              ( mem_idx,
                [
                  Ast.no_loc
                    (B.Const
                       (match limits.desc.address_type with
                       | `I32 -> B.I32 0l
                       | `I64 -> B.I64 0L));
                ] )
          in
          let init = String.concat "" (List.map (fun s -> s.Ast.desc) init) in
          let d = { B.init; mode } in
          scan rest (mem_idx + 1) (d :: acc)
      | { desc = T.Memory _; _ } :: rest -> scan rest (mem_idx + 1) acc
      | _ :: rest -> scan rest mem_idx acc
    in
    scan fields memory_import_count []
  in

  let tags =
    List.filter_map
      (fun f ->
        match f.desc with
        | T.Tag { typ = Some i, _; _ } -> Some (resolve_idx ctx.types i)
        | Tag { typ = None, Some ty; _ } -> Some (resolve_func_type ctx ty)
        | Tag { typ = None, None; _ } ->
            failwith "Tag type must have an explicit type index or inline type"
        | _ -> None)
      fields
  in

  let types =
    explicit_types
    @ (List.rev !extra_types
      |> List.map (fun typ -> [| { B.typ; supertype = None; final = true } |]))
  in

  {
    B.types;
    imports;
    functions;
    tables;
    memories;
    tags;
    globals;
    exports;
    start;
    elem;
    code;
    data;
    names =
      {
        B.module_ = Option.map (fun n -> n.Ast.desc) module_name;
        functions = invert_map ctx.funcs.map;
        locals = !locals_names;
        types = invert_map ctx.types.map;
        fields = B.IntMap.map invert_map field_names;
        tags = invert_map ctx.tags.map;
        globals = invert_map ctx.globals.map;
        tables = invert_map ctx.tables.map;
        memories = invert_map ctx.memories.map;
        data = invert_map ctx.datas.map;
        elem = invert_map ctx.elems.map;
        labels = !labels_names;
      };
  }
