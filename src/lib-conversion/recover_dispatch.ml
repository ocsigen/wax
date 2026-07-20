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
  | { desc = Block { label = Some c; typ; block = { desc = inner; _ } }; _ }
    :: body
    when is_void typ -> (
      match descend inner with
      | Some (arms, br_labels, index) ->
          Some ((c, body) :: arms, br_labels, index)
      | None -> None)
  | _ -> None

(* Recurse into children structurally (no folding here — folding needs the
   statement list, see [rewrite_list]). *)
let rec rewrite_instr (i : location instr) : location instr =
  let d = rewrite_desc i.desc in
  if d == i.desc then i else { i with desc = d }

(* Fold a statement list, recovering a [dispatch] from a switch-wrapper block
   together with the statements that follow it (the outermost case's body).
   Share-preserving: an unfolded list is returned unchanged. *)
and rewrite_list l =
  match l with
  | [] -> []
  | i :: rest -> (
      match try_fold i rest with
      | Some dispatch -> [ dispatch ]
      | None ->
          let i' = rewrite_instr i and rest' = rewrite_list rest in
          if i' == i && rest' == rest then l else i' :: rest')

and try_fold (i : location instr) (trailing : location instr list) :
    location instr option =
  match i.desc with
  | Block { label = Some c0; typ; block } when is_void typ -> (
      match descend block.desc with
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
                            List.map
                              (fun (l, b) -> (l, no_loc (rewrite_list b)))
                              arms;
                        };
                  }
              else None
          | [] -> None)
      | None -> None)
  | _ -> None

and rewrite_desc (desc : location instr_desc) : location instr_desc =
  (* Purely structural recursion; the dispatch folding lives in [rewrite_list].
     Share-preserving, so an untouched subtree is not rebuilt. *)
  Ast_utils.map_desc ~instr:rewrite_instr ~block:rewrite_list desc

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
