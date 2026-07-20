open Ast
module B = Binary
module T = Text

let no_loc = Ast.no_loc
let numeric_index i = no_loc (T.Num (Uint32.of_int i))

(* Render a finite-or-infinite float constant as round-trippable text. A finite
   value uses the hex float form ("%h"), which is exact — unlike
   [string_of_float] ("%.12g"), which truncates (a double needs 17 significant
   digits). An infinity keeps its [string_of_float] spelling ("inf" / "-inf"),
   which the lexers accept; "%h" would print "infinity", which they do not. NaNs
   never reach here: [f32_text]/[f64_text] emit [nan:0xPAYLOAD] for them before
   falling through to this helper, so payloads are preserved. *)
let float_text x =
  if Float.is_finite x then Printf.sprintf "%h" x else string_of_float x

(* Text for an f32 constant given its raw 32 bits. A NaN keeps its exact payload
   as [nan:0xPAYLOAD] (with sign) — routing it through [float_of_bits] would
   quiet a signaling NaN — while any other value uses [float_text]. *)
let f32_text bits =
  let exp = Int32.logand (Int32.shift_right_logical bits 23) 0xFFl in
  let mant = Int32.logand bits 0x7FFFFFl in
  if Int32.equal exp 0xFFl && not (Int32.equal mant 0l) then
    (if Int32.logand bits Int32.min_int <> 0l then "-" else "")
    ^ Printf.sprintf "nan:0x%lx" mant
  else float_text (Int32.float_of_bits bits)

(* Text for an f64 constant. A NaN keeps its payload (f64 bits survive
   [bits_of_float], so the payload is intact); other values use [float_text]. *)
let f64_text x =
  if Float.is_nan x then
    let bits = Int64.bits_of_float x in
    let mant = Int64.logand bits 0xFFFFFFFFFFFFFL in
    (if Int64.logand bits Int64.min_int <> 0L then "-" else "")
    ^ Printf.sprintf "nan:0x%Lx" mant
  else float_text x

let index ~map i =
  match B.IntMap.find_opt i map with
  | Some s -> no_loc (T.Id s)
  | None -> numeric_index i

(* The spine ([heaptype]…[fieldtype]) is a straight copy that only rewrites each
   index to its text name via [index]; [comptype]/[subtype]/[rectype] below stay
   hand-written because they attach type- and field-names from [B.names]. *)
module Map =
  Ast.Map_types_spine (B) (T)
    (struct
      type ctx = B.name_map

      let idx map i = index ~map i
    end)

let heaptype = Map.heaptype
let reftype = Map.reftype
let valtype = Map.valtype
let muttype f (m : 'a B.muttype) : 'b T.muttype = { mut = m.mut; typ = f m.typ }
let fieldtype = Map.fieldtype

let functype type_names (f : B.functype) : T.functype =
  {
    params = Array.map (fun t -> no_loc (None, valtype type_names t)) f.params;
    results = Array.map (valtype type_names) f.results;
  }

let field_name (names : B.names) s_idx f_idx =
  match B.IntMap.find_opt s_idx names.fields with
  | None -> None
  | Some field_map ->
      Option.map (fun nm -> Ast.no_loc nm) (B.IntMap.find_opt f_idx field_map)

let comptype (names : B.names) s_idx (c : B.comptype) : T.comptype =
  match c with
  | Func ft -> Func (functype names.types ft)
  | Struct fa ->
      Struct
        (Array.mapi
           (fun f_idx f ->
             Ast.no_loc (field_name names s_idx f_idx, fieldtype names.types f))
           fa)
  | Array ft -> Array (fieldtype names.types ft)
  | Cont i -> Cont (index ~map:names.types i)

let subtype (names : B.names) idx (s : B.subtype) : T.subtype =
  {
    typ = comptype names idx s.typ;
    supertype = Option.map (index ~map:names.types) s.supertype;
    final = s.final;
    descriptor = Option.map (index ~map:names.types) s.descriptor;
    describes = Option.map (index ~map:names.types) s.describes;
  }

let rectype (names : B.names) index r =
  Array.mapi
    (fun i s ->
      let idx = index + i in
      let name =
        match B.IntMap.find_opt idx names.types with
        | Some s -> Some (no_loc s)
        | None -> None
      in
      no_loc (name, subtype names idx s))
    r

let globaltype type_names g = muttype (valtype type_names) g

let tabletype type_names (t : B.tabletype) : T.tabletype =
  { limits = Ast.no_loc t.limits; reftype = reftype type_names t.reftype }

let blocktype type_names (b : B.blocktype) : T.blocktype =
  match b with
  | Typeuse i -> Typeuse (Some (index ~map:type_names i), None)
  | Valtype v -> Valtype (valtype type_names v)

let get_label_reference stack i =
  match List.nth stack i with
  | Some s -> no_loc (T.Id s)
  | None | (exception Failure _) -> numeric_index i

let catch (names : B.names) stack (c : B.catch) : T.catch =
  match c with
  | Catch (tag, label) ->
      Catch (index ~map:names.tags tag, get_label_reference stack label)
  | CatchRef (tag, label) ->
      CatchRef (index ~map:names.tags tag, get_label_reference stack label)
  | CatchAll label -> CatchAll (get_label_reference stack label)
  | CatchAllRef label -> CatchAllRef (get_label_reference stack label)

let on_clause (names : B.names) stack (c : B.on_clause) : T.on_clause =
  match c with
  | OnLabel (tag, label) ->
      OnLabel (index ~map:names.tags tag, get_label_reference stack label)
  | OnSwitch tag -> OnSwitch (index ~map:names.tags tag)

let get_label_name label_names label_counter =
  let idx = !label_counter in
  incr label_counter;
  B.IntMap.find_opt idx label_names

let field_index (names : B.names) s_idx f_idx =
  match B.IntMap.find_opt s_idx names.fields with
  | Some field_map -> index ~map:field_map f_idx
  | None -> numeric_index f_idx

let rec instr (names : B.names) local_names label_names label_counter stack
    (i : 'info B.instr) =
  let desc : _ T.instr_desc =
    match i.desc with
    | Block { label = _; typ; block } ->
        let name = get_label_name label_names label_counter in
        let stack' = name :: stack in
        Block
          {
            label = Option.map Ast.no_loc name;
            typ = Option.map (blocktype names.types) typ;
            block =
              Ast.no_loc
                (List.map
                   (instr names local_names label_names label_counter stack')
                   block.desc);
          }
    | Loop { label = _; typ; block } ->
        let name = get_label_name label_names label_counter in
        let stack' = name :: stack in
        Loop
          {
            label = Option.map Ast.no_loc name;
            typ = Option.map (blocktype names.types) typ;
            block =
              Ast.no_loc
                (List.map
                   (instr names local_names label_names label_counter stack')
                   block.desc);
          }
    | If { label = _; typ; if_block; else_block } ->
        let name = get_label_name label_names label_counter in
        let stack' = name :: stack in
        If
          {
            label = Option.map Ast.no_loc name;
            typ = Option.map (blocktype names.types) typ;
            (* Keep each arm's decoded byte-offset span (see the decoder's
               [If] case): a per-arm diagnostic anchors there. *)
            if_block =
              {
                Ast.desc =
                  List.map
                    (instr names local_names label_names label_counter stack')
                    if_block.desc;
                info = if_block.info;
              };
            else_block =
              {
                Ast.desc =
                  List.map
                    (instr names local_names label_names label_counter stack')
                    else_block.desc;
                info = else_block.info;
              };
          }
    | TryTable { label = _; typ; catches; block } ->
        let name = get_label_name label_names label_counter in
        let stack' = name :: stack in
        TryTable
          {
            label = Option.map Ast.no_loc name;
            typ = Option.map (blocktype names.types) typ;
            catches = List.map (catch names stack) catches;
            block =
              Ast.no_loc
                (List.map
                   (instr names local_names label_names label_counter stack')
                   block.desc);
          }
    | Try { label = _; typ; block; catches; catch_all } ->
        let name = get_label_name label_names label_counter in
        let stack' = name :: stack in
        Try
          {
            label = Option.map Ast.no_loc name;
            typ = Option.map (blocktype names.types) typ;
            block =
              Ast.no_loc
                (List.map
                   (instr names local_names label_names label_counter stack')
                   block.desc);
            catches =
              List.map
                (fun (tag, b) ->
                  ( index ~map:names.tags tag,
                    Ast.no_loc
                      (List.map
                         (instr names local_names label_names label_counter
                            stack')
                         b.desc) ))
                catches;
            catch_all =
              Option.map
                (fun b ->
                  Ast.no_loc
                    (List.map
                       (instr names local_names label_names label_counter stack')
                       b.desc))
                catch_all;
          }
    | Unreachable -> Unreachable
    | Nop -> Nop
    | Throw i -> Throw (index ~map:names.tags i)
    | ThrowRef -> ThrowRef
    | ContNew i -> ContNew (index ~map:names.types i)
    | ContBind (i, j) ->
        ContBind (index ~map:names.types i, index ~map:names.types j)
    | Suspend i -> Suspend (index ~map:names.tags i)
    | Resume (i, clauses) ->
        Resume
          (index ~map:names.types i, List.map (on_clause names stack) clauses)
    | ResumeThrow (i, j, clauses) ->
        ResumeThrow
          ( index ~map:names.types i,
            index ~map:names.tags j,
            List.map (on_clause names stack) clauses )
    | ResumeThrowRef (i, clauses) ->
        ResumeThrowRef
          (index ~map:names.types i, List.map (on_clause names stack) clauses)
    | Switch (i, j) -> Switch (index ~map:names.types i, index ~map:names.tags j)
    | Br i -> Br (get_label_reference stack i)
    | Br_if i -> Br_if (get_label_reference stack i)
    | Hinted (h, inner) ->
        Hinted (h, instr names local_names label_names label_counter stack inner)
    | Br_table (l, d) ->
        let target i = (get_label_reference stack) i in
        Br_table (List.map target l, target d)
    | Br_on_null i -> Br_on_null (get_label_reference stack i)
    | Br_on_non_null i -> Br_on_non_null (get_label_reference stack i)
    | Br_on_cast (l, r1, r2) ->
        Br_on_cast
          ( get_label_reference stack l,
            reftype names.types r1,
            reftype names.types r2 )
    | Br_on_cast_fail (l, r1, r2) ->
        Br_on_cast_fail
          ( get_label_reference stack l,
            reftype names.types r1,
            reftype names.types r2 )
    | Br_on_cast_desc_eq (l, r1, r2) ->
        Br_on_cast_desc_eq
          ( get_label_reference stack l,
            reftype names.types r1,
            reftype names.types r2 )
    | Br_on_cast_desc_eq_fail (l, r1, r2) ->
        Br_on_cast_desc_eq_fail
          ( get_label_reference stack l,
            reftype names.types r1,
            reftype names.types r2 )
    | Return -> Return
    | Call i -> Call (index ~map:names.functions i)
    | CallRef i -> CallRef (index ~map:names.types i)
    | CallIndirect (table, ty) ->
        CallIndirect
          ( index ~map:names.tables table,
            (Some (index ~map:names.types ty), None) )
    | ReturnCall i -> ReturnCall (index ~map:names.functions i)
    | ReturnCallRef i -> ReturnCallRef (index ~map:names.types i)
    | ReturnCallIndirect (table, ty) ->
        ReturnCallIndirect
          ( index ~map:names.tables table,
            (Some (index ~map:names.types ty), None) )
    | Drop -> Drop
    | Select None -> Select None
    | Select (Some l) -> Select (Some (List.map (valtype names.types) l))
    | LocalGet i -> LocalGet (index ~map:local_names i)
    | LocalSet i -> LocalSet (index ~map:local_names i)
    | LocalTee i -> LocalTee (index ~map:local_names i)
    | GlobalGet i -> GlobalGet (index ~map:names.globals i)
    | GlobalSet i -> GlobalSet (index ~map:names.globals i)
    | Load (o, m, op) -> Load (index ~map:names.memories o, m, op)
    | LoadS (o, m, sz, bt, s) ->
        LoadS (index ~map:names.memories o, m, sz, bt, s)
    | Store (o, m, op) -> Store (index ~map:names.memories o, m, op)
    | StoreS (o, m, sz, bt) -> StoreS (index ~map:names.memories o, m, sz, bt)
    | Atomic (o, op, m) -> Atomic (index ~map:names.memories o, op, m)
    | AtomicFence -> AtomicFence
    | MemorySize i -> MemorySize (index ~map:names.memories i)
    | MemoryGrow i -> MemoryGrow (index ~map:names.memories i)
    | MemoryFill i -> MemoryFill (index ~map:names.memories i)
    | MemoryCopy (i1, i2) ->
        MemoryCopy (index ~map:names.memories i1, index ~map:names.memories i2)
    | MemoryInit (i1, i2) ->
        (* Binary order is (data, memory); text order is (memory, data). Bind
           with lets so the two index spaces are mapped to the right operand. *)
        let data = index ~map:names.data i1 in
        let mem = index ~map:names.memories i2 in
        MemoryInit (mem, data)
    | DataDrop i -> DataDrop (index ~map:names.data i)
    | TableGet i -> TableGet (index ~map:names.tables i)
    | TableSet i -> TableSet (index ~map:names.tables i)
    | TableSize i -> TableSize (index ~map:names.tables i)
    | TableGrow i -> TableGrow (index ~map:names.tables i)
    | TableFill i -> TableFill (index ~map:names.tables i)
    | TableCopy (i1, i2) ->
        TableCopy (index ~map:names.tables i1, index ~map:names.tables i2)
    | TableInit (i1, i2) ->
        (* Binary order is (elem, table); text order is (table, elem). *)
        let elem = index ~map:names.elem i1 in
        let table = index ~map:names.tables i2 in
        TableInit (table, elem)
    | ElemDrop i -> ElemDrop (index ~map:names.elem i)
    | RefNull h -> RefNull (heaptype names.types h)
    | RefFunc i -> RefFunc (index ~map:names.functions i)
    | RefIsNull -> RefIsNull
    | RefAsNonNull -> RefAsNonNull
    | RefEq -> RefEq
    | RefTest r -> RefTest (reftype names.types r)
    | RefCast r -> RefCast (reftype names.types r)
    | RefCastDescEq r -> RefCastDescEq (reftype names.types r)
    | RefGetDesc i -> RefGetDesc (index ~map:names.types i)
    | StructNew i -> StructNew (index ~map:names.types i)
    | StructNewDefault i -> StructNewDefault (index ~map:names.types i)
    | StructNewDesc i -> StructNewDesc (index ~map:names.types i)
    | StructNewDefaultDesc i -> StructNewDefaultDesc (index ~map:names.types i)
    | StructGet (s, s_idx, f_idx) ->
        StructGet
          (s, index ~map:names.types s_idx, field_index names s_idx f_idx)
    | StructSet (s_idx, f_idx) ->
        StructSet (index ~map:names.types s_idx, field_index names s_idx f_idx)
    | ArrayNew i -> ArrayNew (index ~map:names.types i)
    | ArrayNewDefault i -> ArrayNewDefault (index ~map:names.types i)
    | ArrayNewFixed (i, len) -> ArrayNewFixed (index ~map:names.types i, len)
    | ArrayNewData (i1, i2) ->
        ArrayNewData (index ~map:names.types i1, index ~map:names.data i2)
    | ArrayNewElem (i1, i2) ->
        ArrayNewElem (index ~map:names.types i1, index ~map:names.elem i2)
    | ArrayGet (s, i) -> ArrayGet (s, index ~map:names.types i)
    | ArraySet i -> ArraySet (index ~map:names.types i)
    | ArrayLen -> ArrayLen
    | ArrayFill i -> ArrayFill (index ~map:names.types i)
    | ArrayCopy (i1, i2) ->
        ArrayCopy (index ~map:names.types i1, index ~map:names.types i2)
    | ArrayInitData (i1, i2) ->
        ArrayInitData (index ~map:names.types i1, index ~map:names.data i2)
    | ArrayInitElem (i1, i2) ->
        ArrayInitElem (index ~map:names.types i1, index ~map:names.elem i2)
    | RefI31 -> RefI31
    | I31Get s -> I31Get s
    | Const (I32 x) -> Const (I32 (Int32.to_string x))
    | Const (I64 x) -> Const (I64 (Int64.to_string x))
    | Const (F32 x) -> Const (F32 (f32_text x))
    | Const (F64 x) -> Const (F64 (f64_text x))
    | UnOp op -> UnOp op
    | BinOp op -> BinOp op
    | Add128 -> Add128
    | Sub128 -> Sub128
    | MulWide s -> MulWide s
    | I32WrapI64 -> I32WrapI64
    | I64ExtendI32 s -> I64ExtendI32 s
    | F32DemoteF64 -> F32DemoteF64
    | F64PromoteF32 -> F64PromoteF32
    | ExternConvertAny -> ExternConvertAny
    | AnyConvertExtern -> AnyConvertExtern
    | Folded (i1, il) ->
        Folded
          ( instr names local_names label_names label_counter stack i1,
            List.map
              (instr names local_names label_names label_counter stack)
              il )
    | VecLoad (o, op, m) -> VecLoad (index ~map:names.memories o, op, m)
    | VecStore (o, m) -> VecStore (index ~map:names.memories o, m)
    | VecLoadLane (o, op, m, lane) ->
        VecLoadLane (index ~map:names.memories o, op, m, lane)
    | VecStoreLane (o, op, m, lane) ->
        VecStoreLane (index ~map:names.memories o, op, m, lane)
    | VecLoadSplat (o, op, m) ->
        VecLoadSplat (index ~map:names.memories o, op, m)
    | VecConst v -> VecConst (Wax_utils.V128.of_string v)
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
    | String _ | Char _ | If_annotation _ -> (*ZZZZ *) assert false
  in
  { desc; info = i.info }

let expr names local_names e =
  List.map (instr names local_names B.IntMap.empty (ref 0) []) e

let elemmode (names : B.names) local_names (e : _ B.elemmode) : _ T.elemmode =
  match e with
  | Passive -> Passive
  | Active (i, ex) ->
      Active (index ~map:names.tables i, expr names local_names ex)
  | Declare -> Declare

let datamode (names : B.names) local_names (d : _ B.datamode) : _ T.datamode =
  match d with
  | Passive -> Passive
  | Active (i, ex) ->
      Active (index ~map:names.memories i, expr names local_names ex)

let id map idx = Option.map Ast.no_loc (B.IntMap.find_opt idx map)

let unique_names map =
  let seen = Hashtbl.create 16 in
  let suffixes = Hashtbl.create 16 in
  B.IntMap.fold
    (fun idx name acc ->
      if not (Hashtbl.mem seen name) then (
        Hashtbl.add seen name ();
        B.IntMap.add idx name acc)
      else
        let start_i =
          match Hashtbl.find_opt suffixes name with
          | Some i -> i + 1
          | None -> 1
        in
        let rec find_free i =
          let candidate = Printf.sprintf "%s_%d" name i in
          if Hashtbl.mem seen candidate then find_free (i + 1)
          else (candidate, i)
        in
        let new_name, last_i = find_free start_i in
        Hashtbl.replace suffixes name last_i;
        Hashtbl.add seen new_name ();
        B.IntMap.add idx new_name acc)
    map B.IntMap.empty

let unique_names_indirect map = B.IntMap.map unique_names map

let make_names_unique (names : B.names) =
  {
    names with
    functions = unique_names names.functions;
    types = unique_names names.types;
    tags = unique_names names.tags;
    globals = unique_names names.globals;
    tables = unique_names names.tables;
    memories = unique_names names.memories;
    data = unique_names names.data;
    elem = unique_names names.elem;
    locals = unique_names_indirect names.locals;
    labels = unique_names_indirect names.labels;
    fields = unique_names_indirect names.fields;
  }

let split_string s =
  if s = "" then [ "" ]
  else
    let is_utf8 =
      String.is_valid_utf_8 s && not (Wax_utils.Unicode.has_hex_escape s)
    in
    if is_utf8 then
      let len = String.length s in
      (* [start] is the byte offset of the current chunk, [width] its escaped
         display width. When a chunk overflows we prefer to break at
         [last_break] — the offset just past the last space seen (of width
         [width_at_break]) — so words are kept whole; failing that (no space, or
         one so early the chunk would be under 60 columns, leaving too ragged a
         line) we break the word at the current character. *)
      let rec loop acc start i width last_break width_at_break =
        if i >= len then
          List.rev
            (if i > start then String.sub s start (i - start) :: acc else acc)
        else
          let dec = String.get_utf_8_uchar s i in
          let u = Uchar.utf_decode_uchar dec in
          let l = Uchar.utf_decode_length dec in
          let c = Uchar.to_int u in
          let esc_len =
            if c >= 32 && c <> 127 && c <> 34 && c <> 92 then
              Wax_utils.Unicode.char_width width u
            else if c = 9 || c = 10 || c = 13 || c = 34 || c = 92 then 2
            else 3
          in
          if width > 0 && width + esc_len > 75 then
            let break_at, width_before =
              match last_break with
              | Some b when b > start && width_at_break > 60 ->
                  (b, width_at_break)
              | _ -> (i, width)
            in
            loop
              (String.sub s start (break_at - start) :: acc)
              break_at break_at (width - width_before) None 0
          else
            let width = width + esc_len in
            let last_break, width_at_break =
              if c = 32 (* space *) then (Some (i + l), width)
              else (last_break, width_at_break)
            in
            loop acc start (i + l) width last_break width_at_break
      in
      loop [] 0 0 0 None 0
    else
      let chunks = ref [] in
      let rec loop i =
        if i >= String.length s then ()
        else
          let len = min 20 (String.length s - i) in
          chunks := String.sub s i len :: !chunks;
          loop (i + len)
      in
      loop 0;
      List.rev !chunks

let module_ ?features (m : _ B.module_) : _ T.module_ =
  Wax_utils.Debug.timed "to-text" @@ fun () ->
  let m = { m with names = make_names_unique m.names } in
  let all_subtypes =
    Array.concat
      (List.map
         (fun r ->
           let recursive = Array.length r > 1 in
           Array.map (fun t -> (t, recursive)) r)
         m.types)
  in
  let expand_functype func_idx type_idx =
    let local_names =
      match B.IntMap.find_opt func_idx m.names.locals with
      | Some map -> map
      | None -> B.IntMap.empty
    in
    match
      if type_idx < 0 || type_idx >= Array.length all_subtypes then None
      else Some all_subtypes.(type_idx)
    with
    | Some ({ typ = Func ft; supertype; final; _ }, recursive) ->
        let params =
          Array.mapi
            (fun i t ->
              let name = B.IntMap.find_opt i local_names in
              Ast.no_loc (Option.map Ast.no_loc name, valtype m.names.types t))
            ft.params
        in
        let results = Array.map (valtype m.names.types) ft.results in
        ( (if supertype = None && final && not recursive then None
           else Some (index ~map:m.names.types type_idx)),
          { T.params; results } )
    | _ ->
        (* An invalid module can give a function a type index that is out of
           range or does not name a function type. Keep the reference
           unexpanded (with an empty inline signature) rather than crashing;
           validation then reports the bad type. *)
        ( Some (index ~map:m.names.types type_idx),
          { T.params = [||]; results = [||] } )
  in
  let types, _ =
    List.fold_left
      (fun (acc, i) r -> (rectype m.names i r :: acc, i + Array.length r))
      ([], 0) m.types
  in
  let types = List.rev types in
  (* Assign the import an id from the name section and advance the index space
     for its kind. *)
  let id_of (f_i, t_i, m_i, g_i, tg_i) (bdesc : B.importdesc) =
    match bdesc with
    | Func _ -> (id m.names.functions f_i, (f_i + 1, t_i, m_i, g_i, tg_i))
    | Table _ -> (id m.names.tables t_i, (f_i, t_i + 1, m_i, g_i, tg_i))
    | Memory _ -> (id m.names.memories m_i, (f_i, t_i, m_i + 1, g_i, tg_i))
    | Global _ -> (id m.names.globals g_i, (f_i, t_i, m_i, g_i + 1, tg_i))
    | Tag _ -> (id m.names.tags tg_i, (f_i, t_i, m_i, g_i, tg_i + 1))
  in
  let desc_of (f_i, _, _, _, _) (bdesc : B.importdesc) : T.importdesc =
    match bdesc with
    | Func { exact; typ = i } ->
        let typ, sign = expand_functype f_i i in
        T.Func { exact; typ = (typ, Some sign) }
    | Memory l -> T.Memory (Ast.no_loc l)
    | Table t -> T.Table (tabletype m.names.types t)
    | Global gt -> T.Global (globaltype m.names.types gt)
    | Tag i -> T.Tag (Some (index ~map:m.names.types i), None)
  in
  (* Lift one import to (id, text desc), advancing the index space. [desc_of]
     reads the pre-increment counts (matching the func index for locals). *)
  let lift_one counts bdesc =
    let id, counts' = id_of counts bdesc in
    (id, desc_of counts bdesc, counts')
  in
  let counts, imports =
    List.fold_left
      (fun (counts, acc) (entry : B.import_entry) ->
        let field, counts =
          match entry with
          | Single imp ->
              let id, desc, counts = lift_one counts imp.desc in
              ( T.Import
                  {
                    module_ = no_loc imp.module_;
                    name = no_loc imp.name;
                    id;
                    desc;
                    exports = [];
                  },
                counts )
          | Group1 { module_; items } ->
              let counts, ritems =
                List.fold_left
                  (fun (counts, r) (name, bdesc) ->
                    let id, desc, counts = lift_one counts bdesc in
                    (counts, (no_loc name, id, desc) :: r))
                  (counts, []) items
              in
              ( T.Import_group1
                  { module_ = no_loc module_; items = List.rev ritems },
                counts )
          | Group2 { module_; desc; names } ->
              (* The shared type is converted once (with the group's first index)
                 for the printed [Import_group2]; each name still advances the
                 index space and picks up its name-section id (the wax [(item $id
                 …)] extension), so a named Group2 no longer degrades to Group1. *)
              let shared = desc_of counts desc in
              let counts, ritems =
                List.fold_left
                  (fun (counts, r) name ->
                    let id, _, counts = lift_one counts desc in
                    (counts, (no_loc name, id) :: r))
                  (counts, []) names
              in
              ( T.Import_group2
                  {
                    module_ = no_loc module_;
                    desc = shared;
                    items = List.rev ritems;
                  },
                counts )
        in
        (counts, field :: acc))
      ((0, 0, 0, 0, 0), [])
      m.imports
  in
  let func_cnt, table_cnt, mem_cnt, global_cnt, tag_cnt = counts in
  let imports = List.rev imports in
  let funcs =
    List.mapi
      (fun i func_type_idx ->
        let global_idx = func_cnt + i in
        let code = List.nth m.code i in
        let local_names =
          match B.IntMap.find_opt global_idx m.names.locals with
          | Some map -> map
          | None -> B.IntMap.empty
        in
        let label_names =
          match B.IntMap.find_opt global_idx m.names.labels with
          | Some map -> map
          | None -> B.IntMap.empty
        in
        let typ, sign = expand_functype global_idx func_type_idx in
        T.Func
          {
            id = id m.names.functions global_idx;
            typ = (typ, Some sign);
            locals =
              (let offset = Array.length sign.params in
               List.mapi
                 (fun i v ->
                   let name = B.IntMap.find_opt (offset + i) local_names in
                   Ast.no_loc
                     (Option.map Ast.no_loc name, valtype m.names.types v))
                 code.locals);
            instrs =
              List.map
                (instr m.names local_names label_names (ref 0) [])
                code.instrs;
            exports = [];
          })
      m.functions
  in
  let tables =
    List.mapi
      (fun i (t : _ B.table) : _ T.modulefield ->
        let global_idx = table_cnt + i in
        Table
          {
            id = id m.names.tables global_idx;
            typ = tabletype m.names.types t.typ;
            init =
              (match t.expr with
              | Some e -> Init_expr (expr m.names B.IntMap.empty e)
              | None -> Init_default);
            exports = [];
          })
      m.tables
  in
  let memories =
    List.mapi
      (fun i (l : B.limits) : _ T.modulefield ->
        let global_idx = mem_cnt + i in
        Memory
          {
            id = id m.names.memories global_idx;
            limits = Ast.no_loc l;
            init = None;
            exports = [];
          })
      m.memories
  in
  let globals =
    List.mapi
      (fun i (g : _ B.global) : _ T.modulefield ->
        let global_idx = global_cnt + i in
        Global
          {
            id = id m.names.globals global_idx;
            typ = globaltype m.names.types g.typ;
            init = expr m.names B.IntMap.empty g.init;
            exports = [];
          })
      m.globals
  in
  let exports =
    List.map
      (fun (e : B.export) : _ T.modulefield ->
        Export
          {
            name = Ast.no_loc e.name;
            kind = e.kind;
            index =
              (match e.kind with
              | B.Func -> index ~map:m.names.functions e.index
              | B.Tag -> index ~map:m.names.tags e.index
              | B.Global -> index ~map:m.names.globals e.index
              | B.Table -> index ~map:m.names.tables e.index
              | B.Memory -> index ~map:m.names.memories e.index);
          })
      m.exports
  in
  let start =
    Option.map (fun i -> T.Start (index ~map:m.names.functions i)) m.start
  in
  let elems =
    List.mapi
      (fun i (e : _ B.elem) : _ T.modulefield ->
        Elem
          {
            id = id m.names.elem i;
            typ = reftype m.names.types e.typ;
            init = List.map (expr m.names B.IntMap.empty) e.init;
            mode = elemmode m.names B.IntMap.empty e.mode;
          })
      m.elem
  in
  let datas =
    List.mapi
      (fun i (d : _ B.data) : _ T.modulefield ->
        Data
          {
            id = id m.names.data i;
            (* A binary segment is a flat byte string with no run structure. *)
            init =
              List.map (fun s -> Ast.no_loc (T.Str s)) (split_string d.init);
            mode = datamode m.names B.IntMap.empty d.mode;
          })
      m.data
  in
  let tags =
    List.mapi
      (fun i type_idx : _ T.modulefield ->
        let global_idx = tag_cnt + i in
        Tag
          {
            id = id m.names.tags global_idx;
            typ = (Some (index ~map:m.names.types type_idx), None);
            exports = [];
          })
      m.tags
  in
  (* Emit a [(@feature "…")] annotation for each feature the module comes with:
     the union of what the decoder recorded as used ([Feature.used], covering
     binaries whose producer wrote no declaration) and the [target_features]
     custom section's recognised [+] entries (covering a declared-but-unused
     feature, which usage detection cannot see). Other producers' entries are
     not ours to interpret and stay in the binary AST only. *)
  let feature_annotations =
    let used =
      match features with
      | None -> []
      | Some features -> Wax_utils.Feature.used features
    in
    let declared =
      List.filter_map
        (fun (prefix, n) ->
          if prefix = '+' then Wax_utils.Feature.of_name n else None)
        m.target_features
    in
    List.filter_map
      (fun f ->
        if List.mem f used || List.mem f declared then
          Some (T.Feature_annotation (Ast.no_loc (Wax_utils.Feature.name f)))
        else None)
      Wax_utils.Feature.all
  in
  ( Option.map Ast.no_loc m.names.module_,
    List.map Ast.no_loc
      (List.flatten
         [
           feature_annotations;
           List.map (fun t -> T.Types t) types;
           imports;
           funcs;
           tables;
           memories;
           globals;
           exports;
           (match start with Some s -> [ s ] | None -> []);
           elems;
           datas;
           tags;
         ]) )
