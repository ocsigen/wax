open Wax_lang
open Ast

(* Recover the high-level [while] loop from the [loop] shape that
   [Ast_utils.lower_while] produces (and that compilers emit for the
   corresponding source):

     'L: loop { if C { B; br 'L; } }     ⇒  'L?: while C { B }      (leading test)

   so decompiled WAT/WASM (and round-tripped Wax loops) read as the high-level
   form rather than a bare [loop] with an explicit back-edge. A trailing-test
   [loop { B; br_if 'L C; }] has no leading-test [while] equivalent, so it is
   left as a bare [loop].

   The synthesised loop label is kept on the recovered loop only when the body
   still branches to it after the back-edge is removed (a "continue"); otherwise
   it is dropped and the label-less form re-lowers to a fresh synthetic label.
   The reference test is exhaustive and conservative — erring toward keeping the
   label is safe, dropping a still-referenced one would dangle — so a missed
   constructor is a compile error, not silently wrong output.

   Folding is the exact inverse of the lowering, so re-lowering reproduces the
   original [loop] byte-for-byte and the rewrite always preserves runtime
   semantics. Meant to run on {!From_wasm.module_} output, after
   {!Recover_dispatch.module_} and before {!Sink_let.module_} (which would
   otherwise sink locals into the loop body and hide the shape). *)

let is_void (t : functype) = t.params = [||] && t.results = [||]

(* Whether any branch within [i] targets the label [name] — a "continue" to a
   recovered loop, which forces the label to be kept. *)
let rec refs_instr name (i : location instr) : bool =
  let any = List.exists (refs_instr name) in
  let opt = function Some x -> refs_instr name x | None -> false in
  let lab (l : label) = String.equal l.desc name in
  match i.desc with
  | Br (l, e) -> lab l || opt e
  | Br_if (l, e) -> lab l || refs_instr name e
  | Br_table (ls, e) -> List.exists lab ls || refs_instr name e
  | Hinted (_, e) -> refs_instr name e
  | Br_on_null (l, e) | Br_on_non_null (l, e) -> lab l || refs_instr name e
  | Br_on_cast (l, _, e) | Br_on_cast_fail (l, _, e) ->
      lab l || refs_instr name e
  | Br_on_cast_desc_eq (l, _, e, d) | Br_on_cast_desc_eq_fail (l, _, e, d) ->
      lab l || refs_instr name e || refs_instr name d
  | Dispatch { index; cases; default; arms } ->
      lab default || List.exists lab cases || refs_instr name index
      || List.exists (fun (_, b) -> any b) arms
  | Match { scrutinee; arms; default } ->
      refs_instr name scrutinee
      || List.exists (fun (_, b) -> any b) arms
      || any default
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      any block.desc
  | While { cond; step; block; _ } ->
      refs_instr name cond || opt step || any block.desc
  | If { cond; if_block; else_block; _ } -> (
      refs_instr name cond || any if_block.desc
      || match else_block with Some b -> any b.desc | None -> false)
  | Try { block; catches; catch_all; _ } -> (
      any block.desc
      || List.exists (fun (_, b) -> any b) catches
      || match catch_all with Some b -> any b | None -> false)
  | If_annotation { then_body; else_body; _ } -> (
      any then_body.desc
      || match else_body with Some b -> any b.desc | None -> false)
  | Set (_, _, e)
  | Tee (_, e)
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | StructDefaultDesc e
  | ArrayDefault (_, e)
  | UnOp (_, e)
  | ThrowRef e
  | ContNew (_, e) ->
      refs_instr name e
  | Call (a, l) | TailCall (a, l) -> refs_instr name a || any l
  | Struct (_, fs) -> List.exists (fun (_, e) -> opt e) fs
  | StructDesc (d, fs) ->
      refs_instr name d || List.exists (fun (_, e) -> opt e) fs
  | CastDesc (a, _, b)
  | StructSet (a, _, b)
  | Array (_, a, b)
  | ArraySegment (_, _, a, b)
  | ArrayGet (a, b)
  | BinOp (_, a, b) ->
      refs_instr name a || refs_instr name b
  | ArraySet (a, b, c) | Select (a, b, c) ->
      refs_instr name a || refs_instr name b || refs_instr name c
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Sequence l ->
      any l
  | Let (_, e) | Throw (_, e) | Return e -> opt e
  | Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      false

let refs_list name l = List.exists (refs_instr name) l

(* Whether the (already-rewritten) body of void loop [l] still references [l]
   after dropping its back-edge, with [cond] the loop's recovered test. *)
let keep_label l cond body =
  if refs_list l.desc body || refs_instr l.desc cond then Some l else None

(* Whether [i] reads the variable [name] (a [Get]). Conservative: unlisted forms
   report [false], which only makes the induction-step heuristic in [fold_loop]
   fire less often, never wrongly. *)
let rec reads_var name (i : location instr) : bool =
  let any = List.exists (reads_var name) in
  match i.desc with
  | Get id -> String.equal id.desc name
  | BinOp (_, a, b) | ArrayGet (a, b) -> reads_var name a || reads_var name b
  | UnOp (_, e)
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | Hinted (_, e) ->
      reads_var name e
  | Select (a, b, c) -> reads_var name a || reads_var name b || reads_var name c
  | Call (f, args) | TailCall (f, args) -> reads_var name f || any args
  | Tee (id, e) -> String.equal id.desc name || reads_var name e
  | Set (id, _, e) -> String.equal id.desc name || reads_var name e
  | Block { block; _ } | Loop { block; _ } -> any block.desc
  | If { cond; if_block; else_block; _ } -> (
      reads_var name cond || any if_block.desc
      || match else_block with Some b -> any b.desc | None -> false)
  | _ -> false

(* Fold an already-rewritten void [loop] labelled [l] into a [while] when its
   body is the leading-test shape, else leave it a [loop]. *)
let fold_loop l typ block =
  match block.desc with
  (* Leading test: the body is a single label-less void [if] with no else whose
     own body ends in the back-edge. *)
  | [
   {
     desc = If { label = None; typ = it; cond; if_block; else_block = None };
     _;
   };
  ]
    when is_void it -> (
      match List.rev if_block.desc with
      | { desc = Br (bl, None); _ } :: rev_body when String.equal bl.desc l.desc
        -> (
          let body = List.rev rev_body in
          match body with
          (* Continue-expression shape (see [Ast_utils.lower_while]): the body is
             a labelled block (the continue target) whose own body branches to it,
             followed by the step, then the loop back-edge. Recover it as
             [while 'blk cond : (step) { inner }]. *)
          | [
           { desc = Block { label = Some blk; typ = bt; block = inner }; _ };
           step;
          ]
            when is_void bt
                 && (not (String.equal blk.desc l.desc))
                 && refs_list blk.desc inner.desc ->
              While { label = Some blk; cond; step = Some step; block = inner }
          | _ -> (
              let label = keep_label l cond body in
              (* Readability recovery: with no continue (label dropped, so
                 re-lowering is byte-identical), present a trailing
                 induction-variable update — an assignment to a variable the
                 condition reads — as a continue-expression, so index-and-stride
                 loops read as [while i <s n : (i += 1) { … }]. Kept conservative:
                 at least one other body statement must remain. *)
              match (label, List.rev body) with
              | ( None,
                  ({ desc = Set (x, _, _); _ } as step) :: (_ :: _ as rev_rest)
                )
                when reads_var x.desc cond ->
                  While
                    {
                      label = None;
                      cond;
                      step = Some step;
                      block = { block with desc = List.rev rev_rest };
                    }
              | _ ->
                  While
                    {
                      label;
                      cond;
                      step = None;
                      block = { block with desc = body };
                    }))
      | _ -> Loop { label = Some l; typ; block })
  | _ -> Loop { label = Some l; typ; block }

let rec rewrite_instr (i : location instr) : location instr =
  { i with desc = rewrite_desc i.desc }

and rewrite_list l = List.map rewrite_instr l

and rewrite_desc (desc : location instr_desc) : location instr_desc =
  match desc with
  | Loop { label = Some l; typ; block } when is_void typ ->
      fold_loop l typ { block with desc = rewrite_list block.desc }
  | Loop { label; typ; block } ->
      Loop { label; typ; block = { block with desc = rewrite_list block.desc } }
  | Block { label; typ; block } ->
      Block
        { label; typ; block = { block with desc = rewrite_list block.desc } }
  | While { label; cond; step; block } ->
      While
        {
          label;
          cond = rewrite_instr cond;
          step = Option.map rewrite_instr step;
          block = { block with desc = rewrite_list block.desc };
        }
  | If { label; typ; cond; if_block; else_block } ->
      If
        {
          label;
          typ;
          cond = rewrite_instr cond;
          if_block = { if_block with desc = rewrite_list if_block.desc };
          else_block =
            Option.map
              (fun b -> { b with desc = rewrite_list b.desc })
              else_block;
        }
  | TryTable { label; typ; catches; block } ->
      TryTable
        {
          label;
          typ;
          catches;
          block = { block with desc = rewrite_list block.desc };
        }
  | Try { label; typ; block; catches; catch_all } ->
      Try
        {
          label;
          typ;
          block = { block with desc = rewrite_list block.desc };
          catches = List.map (fun (t, l) -> (t, rewrite_list l)) catches;
          catch_all = Option.map rewrite_list catch_all;
        }
  | Dispatch { index; cases; default; arms } ->
      Dispatch
        {
          index = rewrite_instr index;
          cases;
          default;
          arms = List.map (fun (l, b) -> (l, rewrite_list b)) arms;
        }
  | Match { scrutinee; arms; default } ->
      Match
        {
          scrutinee = rewrite_instr scrutinee;
          arms = List.map (fun (p, b) -> (p, rewrite_list b)) arms;
          default = rewrite_list default;
        }
  | If_annotation { cond; then_body; else_body } ->
      If_annotation
        {
          cond;
          then_body = { then_body with desc = rewrite_list then_body.desc };
          else_body =
            Option.map
              (fun b -> { b with desc = rewrite_list b.desc })
              else_body;
        }
  | Set (x, op, e) -> Set (x, op, rewrite_instr e)
  | Tee (x, e) -> Tee (x, rewrite_instr e)
  | Call (t, args) -> Call (rewrite_instr t, List.map rewrite_instr args)
  | TailCall (t, args) -> TailCall (rewrite_instr t, List.map rewrite_instr args)
  | Cast (e, t) -> Cast (rewrite_instr e, t)
  | CastDesc (e, t, d) -> CastDesc (rewrite_instr e, t, rewrite_instr d)
  | Test (e, t) -> Test (rewrite_instr e, t)
  | NonNull e -> NonNull (rewrite_instr e)
  | Struct (idx, fs) ->
      Struct (idx, List.map (fun (n, e) -> (n, Option.map rewrite_instr e)) fs)
  | StructDesc (d, fs) ->
      StructDesc
        ( rewrite_instr d,
          List.map (fun (n, e) -> (n, Option.map rewrite_instr e)) fs )
  | StructDefaultDesc d -> StructDefaultDesc (rewrite_instr d)
  | StructGet (e, x) -> StructGet (rewrite_instr e, x)
  | GetDescriptor e -> GetDescriptor (rewrite_instr e)
  | StructSet (e, x, v) -> StructSet (rewrite_instr e, x, rewrite_instr v)
  | Array (idx, a, b) -> Array (idx, rewrite_instr a, rewrite_instr b)
  | ArrayDefault (idx, e) -> ArrayDefault (idx, rewrite_instr e)
  | ArrayFixed (idx, l) -> ArrayFixed (idx, List.map rewrite_instr l)
  | ArraySegment (idx, d, a, b) ->
      ArraySegment (idx, d, rewrite_instr a, rewrite_instr b)
  | ArrayGet (a, b) -> ArrayGet (rewrite_instr a, rewrite_instr b)
  | ArraySet (a, b, c) ->
      ArraySet (rewrite_instr a, rewrite_instr b, rewrite_instr c)
  | BinOp (op, a, b) -> BinOp (op, rewrite_instr a, rewrite_instr b)
  | UnOp (op, e) -> UnOp (op, rewrite_instr e)
  | Let (bs, e) -> Let (bs, Option.map rewrite_instr e)
  | Br (l, e) -> Br (l, Option.map rewrite_instr e)
  | Br_if (l, e) -> Br_if (l, rewrite_instr e)
  | Hinted (h, e) -> Hinted (h, rewrite_instr e)
  | Br_table (ls, e) -> Br_table (ls, rewrite_instr e)
  | Br_on_null (l, e) -> Br_on_null (l, rewrite_instr e)
  | Br_on_non_null (l, e) -> Br_on_non_null (l, rewrite_instr e)
  | Br_on_cast (l, t, e) -> Br_on_cast (l, t, rewrite_instr e)
  | Br_on_cast_fail (l, t, e) -> Br_on_cast_fail (l, t, rewrite_instr e)
  | Br_on_cast_desc_eq (l, t, e, d) ->
      Br_on_cast_desc_eq (l, t, rewrite_instr e, rewrite_instr d)
  | Br_on_cast_desc_eq_fail (l, t, e, d) ->
      Br_on_cast_desc_eq_fail (l, t, rewrite_instr e, rewrite_instr d)
  | Throw (idx, e) -> Throw (idx, Option.map rewrite_instr e)
  | ThrowRef e -> ThrowRef (rewrite_instr e)
  | ContNew (ct, e) -> ContNew (ct, rewrite_instr e)
  | ContBind (src, dst, l) -> ContBind (src, dst, List.map rewrite_instr l)
  | Suspend (tag, l) -> Suspend (tag, List.map rewrite_instr l)
  | Resume (ct, h, l) -> Resume (ct, h, List.map rewrite_instr l)
  | ResumeThrow (ct, tag, h, l) ->
      ResumeThrow (ct, tag, h, List.map rewrite_instr l)
  | ResumeThrowRef (ct, h, l) -> ResumeThrowRef (ct, h, List.map rewrite_instr l)
  | Switch (ct, tag, l) -> Switch (ct, tag, List.map rewrite_instr l)
  | Return e -> Return (Option.map rewrite_instr e)
  | Sequence l -> Sequence (List.map rewrite_instr l)
  | Select (a, b, c) ->
      Select (rewrite_instr a, rewrite_instr b, rewrite_instr c)
  | ( Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _
    | Int _ | Float _ | StructDefault _ ) as x ->
      x

let rec field_desc (f : location modulefield) =
  let map_fields = List.map (fun a -> { a with desc = field_desc a.desc }) in
  match f with
  | Func ({ body = label, instrs; _ } as r) ->
      Func { r with body = (label, rewrite_list instrs) }
  | Conditional ({ then_fields; else_fields; _ } as r) ->
      Conditional
        {
          r with
          then_fields = { then_fields with desc = map_fields then_fields.desc };
          else_fields =
            Option.map
              (fun b -> { b with desc = map_fields b.desc })
              else_fields;
        }
  | ( Type _ | Module_annotation _ | Import _ | Import_group _ | Global _
    | Tag _ | Memory _ | Data _ | Table _ | Elem _ ) as f ->
      f

let module_ (m : location module_) : location module_ =
  List.map (fun a -> { a with desc = field_desc a.desc }) m
