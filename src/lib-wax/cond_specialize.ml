module CS = Wax_wasm.Cond_specialize
open Ast

(* Splice out / simplify every conditional in a Wax module, returning the byte
   ranges of removed branches so their comments can be dropped (see
   {!Wax_utils.Trivia.drop_in_ranges}). The set of nodes recursed through matches
   [Typing.specialize_fields]; the difference is that an undetermined
   conditional is kept (with its condition simplified) rather than explored. The
   split between branches is the end of the then-branch (just before the
   [#[else]]), avoiding any need for the [#[else]] token's own position. *)
let module_ ctx env (fields : location Ast.module_) :
    location Ast.module_ * (int * int) list =
  Wax_utils.Debug.timed "specialize" @@ fun () ->
  let eval cond = CS.eval ctx env cond in
  let ranges = ref [] in
  let start_of (l : location) = l.loc_start.Lexing.pos_cnum in
  let end_of (l : location) = l.loc_end.Lexing.pos_cnum in
  let branch_end ~default nodes =
    match List.rev nodes with n :: _ -> end_of n.info | [] -> default
  in
  (* The boundary between the two branches. With no else the conditional ends at
     the then-branch, so its own end (past any closing brace) is exact; with an
     else, the best position the AST offers is the end of the last then-node. *)
  let split loc then_nodes ~else_present =
    if else_present then branch_end ~default:(end_of loc) then_nodes
    else end_of loc
  in
  (* Then kept, else dropped: span from the boundary to the conditional's end. *)
  let drop_else loc then_nodes ~else_present =
    ranges := (split loc then_nodes ~else_present, end_of loc) :: !ranges
  in
  (* Else kept (or nothing), then dropped: span from the conditional's start
     through the boundary. *)
  let drop_then loc then_nodes ~else_present =
    ranges := (start_of loc, split loc then_nodes ~else_present) :: !ranges
  in
  let rec sinstrs l = List.concat_map sinstr l
  and sinstr (i : location instr) : location instr list =
    match i.desc with
    | If_annotation { cond; then_body; else_body } -> (
        let else_present = Option.is_some else_body in
        match eval cond with
        | True ->
            drop_else i.info then_body.desc ~else_present;
            sinstrs then_body.desc
        | False -> (
            drop_then i.info then_body.desc ~else_present;
            match else_body with Some e -> sinstrs e.desc | None -> [])
        | Residual cond ->
            [
              {
                i with
                desc =
                  If_annotation
                    {
                      cond;
                      then_body =
                        { then_body with desc = sinstrs then_body.desc };
                      else_body =
                        Option.map
                          (fun b -> { b with desc = sinstrs b.desc })
                          else_body;
                    };
              };
            ])
    | desc -> [ { i with desc = sdesc desc } ]
  (* [sone] is for single-instruction positions, where an [If_annotation]
     (statement-only) cannot appear, so the result is always a singleton. *)
  and sone i = match sinstr i with [ x ] -> x | _ -> assert false
  and sdesc (desc : location instr_desc) : location instr_desc =
    match desc with
    | Block { label; typ; block } ->
        Block { label; typ; block = { block with desc = sinstrs block.desc } }
    | Loop { label; typ; block } ->
        Loop { label; typ; block = { block with desc = sinstrs block.desc } }
    | While { label; cond; step; block } ->
        While
          {
            label;
            cond = sone cond;
            step = Option.map sone step;
            block = { block with desc = sinstrs block.desc };
          }
    | If { label; typ; cond; if_block; else_block } ->
        If
          {
            label;
            typ;
            cond = sone cond;
            if_block = { if_block with desc = sinstrs if_block.desc };
            else_block =
              Option.map (fun b -> { b with desc = sinstrs b.desc }) else_block;
          }
    | TryTable { label; typ; catches; block } ->
        TryTable
          {
            label;
            typ;
            catches;
            block = { block with desc = sinstrs block.desc };
          }
    | Try { label; typ; block; catches; catch_all } ->
        Try
          {
            label;
            typ;
            block = { block with desc = sinstrs block.desc };
            catches = List.map (fun (t, l) -> (t, sinstrs l)) catches;
            catch_all = Option.map sinstrs catch_all;
          }
    | Set (idx, op, v) -> Set (idx, op, sone v)
    | Tee (idx, v) -> Tee (idx, sone v)
    | Call (t, args) -> Call (sone t, List.map sone args)
    | TailCall (t, args) -> TailCall (sone t, List.map sone args)
    | Cast (v, t) -> Cast (sone v, t)
    | CastDesc (v, t, d) -> CastDesc (sone v, t, sone d)
    | Test (v, t) -> Test (sone v, t)
    | NonNull v -> NonNull (sone v)
    | Struct (idx, fields) ->
        Struct (idx, List.map (fun (i, v) -> (i, Option.map sone v)) fields)
    | StructDesc (d, fields) ->
        StructDesc
          (sone d, List.map (fun (i, v) -> (i, Option.map sone v)) fields)
    | StructDefaultDesc d -> StructDefaultDesc (sone d)
    | StructGet (v, idx) -> StructGet (sone v, idx)
    | GetDescriptor v -> GetDescriptor (sone v)
    | StructSet (v, idx, w) -> StructSet (sone v, idx, sone w)
    | Array (idx, a, b) -> Array (idx, sone a, sone b)
    | ArrayDefault (idx, v) -> ArrayDefault (idx, sone v)
    | ArrayFixed (idx, l) -> ArrayFixed (idx, List.map sone l)
    | ArraySegment (idx, d, a, b) -> ArraySegment (idx, d, sone a, sone b)
    | ArrayGet (a, b) -> ArrayGet (sone a, sone b)
    | ArraySet (a, b, c) -> ArraySet (sone a, sone b, sone c)
    | BinOp (op, a, b) -> BinOp (op, sone a, sone b)
    | UnOp (op, v) -> UnOp (op, sone v)
    | Let (bs, body) -> Let (bs, Option.map sone body)
    | Br (l, v) -> Br (l, Option.map sone v)
    | Br_if (l, v) -> Br_if (l, sone v)
    | Hinted (h, i) -> Hinted (h, sone i)
    | Br_table (ls, v) -> Br_table (ls, sone v)
    | Dispatch { index; cases; default; arms } ->
        Dispatch
          {
            index = sone index;
            cases;
            default;
            arms = List.map (fun (l, body) -> (l, sinstrs body)) arms;
          }
    | Match { scrutinee; arms; default } ->
        Match
          {
            scrutinee = sone scrutinee;
            arms = List.map (fun (pat, body) -> (pat, sinstrs body)) arms;
            default = sinstrs default;
          }
    | Br_on_null (l, v) -> Br_on_null (l, sone v)
    | Br_on_non_null (l, v) -> Br_on_non_null (l, sone v)
    | Br_on_cast (l, t, v) -> Br_on_cast (l, t, sone v)
    | Br_on_cast_fail (l, t, v) -> Br_on_cast_fail (l, t, sone v)
    | Br_on_cast_desc_eq (l, t, v, d) ->
        Br_on_cast_desc_eq (l, t, sone v, sone d)
    | Br_on_cast_desc_eq_fail (l, t, v, d) ->
        Br_on_cast_desc_eq_fail (l, t, sone v, sone d)
    | Throw (idx, v) -> Throw (idx, Option.map sone v)
    | ThrowRef v -> ThrowRef (sone v)
    | ContNew (ct, v) -> ContNew (ct, sone v)
    | ContBind (src, dst, l) -> ContBind (src, dst, List.map sone l)
    | Suspend (tag, l) -> Suspend (tag, List.map sone l)
    | Resume (ct, h, l) -> Resume (ct, h, List.map sone l)
    | ResumeThrow (ct, tag, h, l) -> ResumeThrow (ct, tag, h, List.map sone l)
    | ResumeThrowRef (ct, h, l) -> ResumeThrowRef (ct, h, List.map sone l)
    | Switch (ct, tag, l) -> Switch (ct, tag, List.map sone l)
    | Return v -> Return (Option.map sone v)
    | Sequence l -> Sequence (sinstrs l)
    | Select (c, t, e) -> Select (sone c, sone t, sone e)
    | If_annotation _ -> assert false (* handled in [sinstr] *)
    | ( Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _
      | Int _ | Float _ | StructDefault _ ) as x ->
        x
  in
  let rec sfields fl = List.concat_map sfield fl
  and sfield (f : (location modulefield, location) annotated) =
    match f.desc with
    | Conditional { cond; then_fields; else_fields } -> (
        let else_present = Option.is_some else_fields in
        match eval cond with
        | True ->
            drop_else f.info then_fields ~else_present;
            sfields then_fields
        | False -> (
            drop_then f.info then_fields ~else_present;
            match else_fields with Some e -> sfields e | None -> [])
        | Residual cond ->
            [
              {
                f with
                desc =
                  Conditional
                    {
                      cond;
                      then_fields = sfields then_fields;
                      else_fields = Option.map sfields else_fields;
                    };
              };
            ])
    | Group { attributes; fields } ->
        [ { f with desc = Group { attributes; fields = sfields fields } } ]
    | Func ({ body = lbl, instrs; _ } as r) ->
        [ { f with desc = Func { r with body = (lbl, sinstrs instrs) } } ]
    | Global ({ def; _ } as g) ->
        [ { f with desc = Global { g with def = sone def } } ]
    | _ -> [ f ]
  in
  let fields = sfields fields in
  (fields, List.rev !ranges)
