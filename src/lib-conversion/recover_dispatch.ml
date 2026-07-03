open Wax_lang
open Ast

(* Recover a [dispatch] from the conventional dense-switch shape that compilers
   emit (and that [Ast_utils.lower_dispatch] reproduces): a stack of void blocks,
   one per case, with a [br_table] in the innermost and each case body just after
   its block. The outermost block's case body is the code *following* that block,
   so recovery folds the block together with the statements after it:

     'c_0: { 'c_1: { … 'c_k: { br_table […] idx } b_k } … b_1 }  b_0   (b_0 = following stmts)
     ⇒ dispatch idx [ … ] { 'c_k: { b_k } … 'c_1: { b_1 } 'c_0: { b_0 } }

   Arms come out in fall-through order — innermost case first — which is the
   reverse of the block nesting, so a case's body falls through into the *next*
   arm listed, not the previous one. So decompiled WAT/WASM jump tables (and
   round-tripped Wax dispatches) read as the high-level form, every case an arm,
   rather than a pile of blocks.

   Folding is the exact inverse of the lowering — re-lowering reproduces the
   original blocks byte-for-byte — so it always preserves runtime semantics; the
   matcher just confirms the shape.

   Cost. [descend] follows only the leading-child chain and stops at the first
   element that breaks it; the chain nodes are the case blocks, none of which
   heads another chain, so each node is walked by at most one descent and the
   pass is linear in the AST. *)

let is_void (t : functype) = t.params = [||] && t.results = [||]

(* Peel the case-block chain inside the outermost block, collecting the inner
   cases (with their bodies), plus the [br_table]'s full label list and index. *)
let rec descend block =
  match block with
  | [ { desc = Br_table (br_labels, index); _ } ] -> Some ([], br_labels, index)
  | { desc = Block { label = Some c; typ; block = inner }; _ } :: body
    when is_void typ -> (
      match descend inner with
      | Some (arms, br_labels, index) ->
          Some ((c, body) :: arms, br_labels, index)
      | None -> None)
  | _ -> None

(* Recurse into children structurally (no folding here — folding needs the
   statement list, see [rewrite_list]). *)
let rec rewrite_instr (i : location instr) : location instr =
  { i with desc = rewrite_desc i.desc }

(* Fold a statement list, recovering a [dispatch] from a switch-wrapper block
   together with the statements that follow it (the outermost case's body). *)
and rewrite_list = function
  | [] -> []
  | i :: rest -> (
      match try_fold i rest with
      | Some dispatch -> [ dispatch ]
      | None -> rewrite_instr i :: rewrite_list rest)

and try_fold (i : location instr) (trailing : location instr list) :
    location instr option =
  match i.desc with
  | Block { label = Some c0; typ; block } when is_void typ -> (
      match descend block with
      | Some (inner_arms, br_labels, index) -> (
          match List.rev br_labels with
          | default :: rev_cases ->
              let cases = List.rev rev_cases in
              (* Arms in fall-through order: innermost case first, the outermost
                 block [c0] (whose body is the trailing code) last. *)
              let arms = List.rev ((c0, trailing) :: inner_arms) in
              let arm_names = List.map (fun ((l : label), _) -> l.desc) arms in
              let br_names = List.map (fun (l : label) -> l.desc) br_labels in
              (* Case labels become distinct, name-keyed arms; and the outermost
                 block must itself be a [br_table] target (it is, in a real
                 switch — index 0 or the default lands there), which keeps us from
                 folding an unrelated enclosing block and swallowing the code
                 after it. *)
              let distinct =
                List.length (List.sort_uniq compare arm_names)
                = List.length arm_names
              in
              if distinct && List.mem c0.desc br_names then
                Some
                  {
                    i with
                    desc =
                      Dispatch
                        {
                          index = rewrite_instr index;
                          cases;
                          default;
                          arms =
                            List.map (fun (l, b) -> (l, rewrite_list b)) arms;
                        };
                  }
              else None
          | [] -> None)
      | None -> None)
  | _ -> None

and rewrite_desc (desc : location instr_desc) : location instr_desc =
  match desc with
  | Block { label; typ; block } ->
      Block { label; typ; block = rewrite_list block }
  | Loop { label; typ; block } ->
      Loop { label; typ; block = rewrite_list block }
  | While { label; cond; block } ->
      While { label; cond = rewrite_instr cond; block = rewrite_list block }
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
      TryTable { label; typ; catches; block = rewrite_list block }
  | Try { label; typ; block; catches; catch_all } ->
      Try
        {
          label;
          typ;
          block = rewrite_list block;
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
          then_body = rewrite_list then_body;
          else_body = Option.map rewrite_list else_body;
        }
  | Set (x, e) -> Set (x, rewrite_instr e)
  | Tee (x, e) -> Tee (x, rewrite_instr e)
  | Call (t, args) -> Call (rewrite_instr t, List.map rewrite_instr args)
  | TailCall (t, args) -> TailCall (rewrite_instr t, List.map rewrite_instr args)
  | Cast (e, t) -> Cast (rewrite_instr e, t)
  | CastDesc (e, t, d) -> CastDesc (rewrite_instr e, t, rewrite_instr d)
  | Test (e, t) -> Test (rewrite_instr e, t)
  | NonNull e -> NonNull (rewrite_instr e)
  | Struct (idx, fs) ->
      Struct (idx, List.map (fun (n, e) -> (n, rewrite_instr e)) fs)
  | StructDesc (d, fs) ->
      StructDesc
        (rewrite_instr d, List.map (fun (n, e) -> (n, rewrite_instr e)) fs)
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
  | Group ({ fields; _ } as r) -> Group { r with fields = map_fields fields }
  | Conditional ({ then_fields; else_fields; _ } as r) ->
      Conditional
        {
          r with
          then_fields = map_fields then_fields;
          else_fields = Option.map map_fields else_fields;
        }
  | ( Type _ | Module_annotation _ | Fundecl _ | GlobalDecl _ | Global _ | Tag _
    | Memory _ | Data _ | Table _ | Elem _ ) as f ->
      f

let module_ (m : location module_) : location module_ =
  List.map (fun a -> { a with desc = field_desc a.desc }) m
