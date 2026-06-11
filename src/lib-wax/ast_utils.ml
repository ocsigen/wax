open Ast

let rec map_instr f instr =
  let desc =
    match instr.desc with
    | Block { label; typ; block = instrs } ->
        Block { label; typ; block = List.map (map_instr f) instrs }
    | Loop { label; typ; block = instrs } ->
        Loop { label; typ; block = List.map (map_instr f) instrs }
    | If { label; typ; cond; if_block; else_block } ->
        If
          {
            label;
            typ;
            cond = map_instr f cond;
            if_block =
              { if_block with desc = List.map (map_instr f) if_block.desc };
            else_block =
              Option.map
                (fun b -> { b with desc = List.map (map_instr f) b.desc })
                else_block;
          }
    | TryTable { label; typ; block; catches } ->
        TryTable { label; typ; block = List.map (map_instr f) block; catches }
    | Try { label; typ; block; catches; catch_all } ->
        Try
          {
            label;
            typ;
            block = List.map (map_instr f) block;
            catches =
              List.map
                (fun (tag, block) -> (tag, List.map (map_instr f) block))
                catches;
            catch_all = Option.map (List.map (map_instr f)) catch_all;
          }
    | ( Unreachable | Nop | Hole | Null | Get _ | Char _ | String _ | Int _
      | Float _ | StructDefault _ ) as x ->
        x
    | Set (idx, v) -> Set (idx, map_instr f v)
    | Tee (idx, v) -> Tee (idx, map_instr f v)
    | Call (target, args) ->
        Call (map_instr f target, List.map (map_instr f) args)
    | TailCall (target, args) ->
        TailCall (map_instr f target, List.map (map_instr f) args)
    | Cast (v, t) -> Cast (map_instr f v, t)
    | Test (v, t) -> Test (map_instr f v, t)
    | NonNull v -> NonNull (map_instr f v)
    | Struct (idx, fields) ->
        Struct (idx, List.map (fun (i, v) -> (i, map_instr f v)) fields)
    | StructGet (v, idx) -> StructGet (map_instr f v, idx)
    | StructSet (v, idx, w) -> StructSet (map_instr f v, idx, map_instr f w)
    | Array (idx, len, init) -> Array (idx, map_instr f len, map_instr f init)
    | ArrayDefault (idx, len) -> ArrayDefault (idx, map_instr f len)
    | ArrayFixed (idx, elems) -> ArrayFixed (idx, List.map (map_instr f) elems)
    | ArraySegment (idx, seg, off, len) ->
        ArraySegment (idx, seg, map_instr f off, map_instr f len)
    | ArrayGet (arr, idx) -> ArrayGet (map_instr f arr, map_instr f idx)
    | ArraySet (arr, idx, val_) ->
        ArraySet (map_instr f arr, map_instr f idx, map_instr f val_)
    | BinOp (op, l, r) -> BinOp (op, map_instr f l, map_instr f r)
    | UnOp (op, v) -> UnOp (op, map_instr f v)
    | Let (bindings, body) -> Let (bindings, Option.map (map_instr f) body)
    | Br (label, v) -> Br (label, Option.map (map_instr f) v)
    | Br_if (label, v) -> Br_if (label, map_instr f v)
    | Br_table (labels, v) -> Br_table (labels, map_instr f v)
    | Dispatch { index; cases; default; arms } ->
        Dispatch
          {
            index = map_instr f index;
            cases;
            default;
            arms =
              List.map (fun (l, body) -> (l, List.map (map_instr f) body)) arms;
          }
    | Br_on_null (label, v) -> Br_on_null (label, map_instr f v)
    | Br_on_non_null (label, v) -> Br_on_non_null (label, map_instr f v)
    | Br_on_cast (label, t, v) -> Br_on_cast (label, t, map_instr f v)
    | Br_on_cast_fail (label, t, v) -> Br_on_cast_fail (label, t, map_instr f v)
    | Throw (idx, args) -> Throw (idx, Option.map (map_instr f) args)
    | ThrowRef v -> ThrowRef (map_instr f v)
    | ContNew (ct, v) -> ContNew (ct, map_instr f v)
    | ContBind (src, dst, args) ->
        ContBind (src, dst, List.map (map_instr f) args)
    | Suspend (tag, args) -> Suspend (tag, List.map (map_instr f) args)
    | Resume (ct, handlers, args) ->
        Resume (ct, handlers, List.map (map_instr f) args)
    | ResumeThrow (ct, tag, handlers, args) ->
        ResumeThrow (ct, tag, handlers, List.map (map_instr f) args)
    | ResumeThrowRef (ct, handlers, args) ->
        ResumeThrowRef (ct, handlers, List.map (map_instr f) args)
    | Switch (ct, tag, args) -> Switch (ct, tag, List.map (map_instr f) args)
    | Return v -> Return (Option.map (map_instr f) v)
    | Sequence instrs -> Sequence (List.map (map_instr f) instrs)
    | Select (cond, t, e) ->
        Select (map_instr f cond, map_instr f t, map_instr f e)
    | If_annotation { cond; then_body; else_body } ->
        If_annotation
          {
            cond;
            then_body = List.map (map_instr f) then_body;
            else_body = Option.map (List.map (map_instr f)) else_body;
          }
  in
  { desc; info = f instr.info }

(* Lower a [dispatch] to the conventional dense-switch shape: one nested void
   block per case (in arm order, the first arm outermost), the [br_table] in the
   innermost block, and each case body placed just after its block. Branching to
   case [cᵢ] exits its block and runs [cᵢ]'s body (then falls through into the
   enclosing cases). So [cᵢ]'s body sits in [cᵢ₋₁]'s block — and the first
   (outermost) arm's body trails the whole structure, hence the result is an
   instruction *list*: the outermost block followed by that trailing body.

   This is the exact inverse of {!Recover_dispatch}, so a recovered dispatch
   re-lowers to the original blocks byte-for-byte. Every synthesised block and
   the [br_table] carry [block_info]; the index and case bodies keep their own. *)
let lower_dispatch ~block_info ~index ~cases ~default ~arms =
  let mk desc = { desc; info = block_info } in
  let void = { params = [||]; results = [||] } in
  let br = mk (Br_table (cases @ [ default ], index)) in
  let rec build = function
    | [ (c, _) ] ->
        (* innermost case block holds just the [br_table] *)
        mk (Block { label = Some c; typ = void; block = [ br ] })
    | (c, _) :: ((_, next_body) :: _ as rest) ->
        mk
          (Block { label = Some c; typ = void; block = build rest :: next_body })
    | [] -> br
  in
  match arms with
  | [] -> [ br ]
  | (_, first_body) :: _ -> build arms :: first_body

let rec map_modulefield f field =
  match field with
  | Type t -> Type t
  | Fundecl f -> Fundecl f
  | GlobalDecl g -> GlobalDecl g
  | Tag t -> Tag t
  | Func ({ body = s, instrs; _ } as func) ->
      Func { func with body = (s, List.map (map_instr f) instrs) }
  | Global g -> Global { g with def = map_instr f g.def }
  | Memory m ->
      Memory
        {
          m with
          data =
            List.map (fun d -> { d with offset = map_instr f d.offset }) m.data;
        }
  | Data ({ mode; _ } as d) ->
      Data
        {
          d with
          mode =
            (match mode with
            | Passive -> Passive
            | Active (mem, off) -> Active (mem, map_instr f off));
        }
  | Table ({ init; _ } as t) ->
      Table { t with init = Option.map (map_instr f) init }
  | Elem ({ mode; init; _ } as e) ->
      Elem
        {
          e with
          mode =
            (match mode with
            | EPassive -> EPassive
            | EActive (tab, off) -> EActive (tab, map_instr f off));
          init = List.map (map_instr f) init;
        }
  | Group { attributes; fields } ->
      Group
        {
          attributes;
          fields =
            List.map
              (fun a -> { a with desc = map_modulefield f a.desc })
              fields;
        }
  | Conditional { cond; then_fields; else_fields } ->
      let map_fields =
        List.map (fun a -> { a with desc = map_modulefield f a.desc })
      in
      Conditional
        {
          cond;
          then_fields = map_fields then_fields;
          else_fields = Option.map map_fields else_fields;
        }

let rec iter_fields f l =
  List.iter
    (fun field ->
      f field;
      match field.desc with
      | Group { fields; _ } -> iter_fields f fields
      | Conditional { then_fields; else_fields; _ } ->
          iter_fields f then_fields;
          Option.iter (iter_fields f) else_fields
      | _ -> ())
    l
