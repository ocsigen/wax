open Wax
open Ast

(* Recover a [match] from the nested type-test ladder that
   {!Ast_utils.lower_match} emits (and that hand-written GC code uses): a stack
   of blocks, the innermost holding a threaded [br_on_cast]/[br_on_null] chain on
   the scrutinee, each test branching out to its arm's block, with the arm body
   after that block and a void [escape] block past them all; the [default]
   follows the [escape] block as trailing code.

     'escape: do {
       'Lₙ₋₁: do { … 'L₀: do { _ = br_on_cast 'L₀ … (br_on_cast 'L₁ … (… v)); br 'escape }
                        <bind/​drop block 'L₀>; arm₀ } … <bind/​drop>; armₙ₋₁ }
       …trailing default…
     ⇒ match v { …armᵢ… _ => { …trailing… } }

   Because every arm body leaves the [match] (diverges), absorbing the trailing
   statements into the default preserves semantics — they only run on the
   no-match (fall-through) path. Bound cast arms surface their binding as a
   [local.set] ([Set] / a fused [let]); {!Sink_let} may float the bare local
   declaration of an inner arm out to an enclosing ladder block, so the descent
   skips leading bare declarations (the fold discards them — re-lowering
   reintroduces each binding). Folding is the exact inverse of the lowering, so a
   Wax [match] round-trips through the binary. Meant to run on {!Sink_let.module_}
   output. *)

let is_block i = match i.desc with Block _ -> true | _ -> false

let is_chain i =
  match i.desc with Br_on_cast _ | Br_on_null _ -> true | _ -> false

(* Parse the threaded chain (innermost operand the scrutinee). Returns the tests
   in source order — innermost test ([L₀]) first — each as its label and the
   pattern's cast target ([`Cast]) or null ([`Null]); the binding (if any) comes
   from the wrapping block's consume, not the chain. *)
let rec chain_tests e =
  match e.desc with
  | Br_on_cast (l, rt, operand) ->
      let tests, scrut = chain_tests operand in
      (tests @ [ (l, `Cast rt) ], scrut)
  | Br_on_null (l, operand) ->
      let tests, scrut = chain_tests operand in
      (tests @ [ (l, `Null) ], scrut)
  | _ -> ([], e)

(* Skip leading bare local declarations [let x;]: bindings for inner arms that
   {!Sink_let} floated out to this ladder block. The fold discards them. *)
let rec skip_decls stmts =
  match stmts with
  | { desc = Let ([ (Some _, _) ], None); _ } :: rest -> skip_decls rest
  | _ -> stmts

(* Strip a ladder block's consume of its inner block, returning the binding
   ([Some x] for a bound cast arm), that inner block, and the trailing arm body.
   A [null] arm consumes nothing (a bare block), an unbound cast drops the
   block ([Set None]), a bound cast binds it ([Set Some] / a fused [let]). *)
let consume_step stmts =
  match skip_decls stmts with
  | { desc = Let ([ (Some x, _) ], Some inner); _ } :: body when is_block inner
    ->
      Some (Some x, inner, body)
  | { desc = Set (Some x, inner); _ } :: body when is_block inner ->
      Some (Some x, inner, body)
  | { desc = Set (None, inner); _ } :: body when is_block inner ->
      Some (None, inner, body)
  | ({ desc = Block _; _ } as inner) :: body -> Some (None, inner, body)
  | _ -> None

(* Descend the ladder from block [blk]. Returns the wrapper levels (outer→inner,
   one per arm: the block label, the arm's binding, and its body), then the
   innermost block's label, the chain, and the escape label. *)
let rec descend blk =
  match blk.desc with
  | Block { label = Some lbl; block = body; _ } -> (
      match body with
      | [ { desc = Set (None, chain); _ }; { desc = Br (escape, None); _ } ]
        when is_chain chain ->
          Some ([], lbl, chain, escape)
      | _ -> (
          match consume_step body with
          | Some (binding, inner, arm_body) -> (
              match descend inner with
              | Some (levels, inner_lbl, chain, escape) ->
                  Some
                    ( (lbl, binding, arm_body) :: levels,
                      inner_lbl,
                      chain,
                      escape )
              | None -> None)
          | None -> None))
  | _ -> None

let rec rewrite_instr (i : location instr) : location instr =
  { i with desc = rewrite_desc i.desc }

(* Fold the [escape] block [i] (and the trailing statements after it, which
   become the default) into a [match]. *)
and try_fold (i : location instr) (trailing : location instr list) :
    location instr option =
  match descend i with
  | None -> None
  | Some (levels, inner_lbl, chain, escape) ->
      let tests, scrut = chain_tests chain in
      let n = List.length tests in
      (* Each test branches to its arm's block; descending nests them
         innermost→outermost as the chain orders them, with the escape block
         outermost. Checking that pins the fold to a genuine ladder. *)
      let block_labels =
        inner_lbl :: List.rev_map (fun (l, _, _) -> l) levels
      in
      let rec take k = function
        | x :: r when k > 0 -> x :: take (k - 1) r
        | _ -> []
      in
      let label_names = List.map (fun (l : label) -> l.desc) block_labels in
      let distinct =
        List.length (List.sort_uniq compare label_names)
        = List.length label_names
      in
      let chain_ok =
        List.length levels = n
        && List.map (fun ((l : label), _) -> l.desc) tests = take n label_names
        &&
        match List.rev block_labels with
        | last :: _ -> last.desc = escape.desc
        | [] -> false
      in
      if n < 1 || (not distinct) || not chain_ok then None
      else
        let arm (_, pat_kind) (_, binding, body) =
          let pat =
            match (pat_kind, binding) with
            | `Cast rt, Some x -> Some (MatchCast (Some x, rt))
            | `Cast rt, None -> Some (MatchCast (None, rt))
            | `Null, None -> Some MatchNull
            | `Null, Some _ -> None
          in
          Option.map (fun pat -> (pat, rewrite_list body)) pat
        in
        let arms = List.map2 arm tests (List.rev levels) in
        if List.exists Option.is_none arms then None
        else
          Some
            {
              i with
              desc =
                Match
                  {
                    scrutinee = rewrite_instr scrut;
                    arms = List.filter_map Fun.id arms;
                    default = rewrite_list trailing;
                  };
            }

and rewrite_list stmts =
  match stmts with
  | [] -> []
  | i :: rest -> (
      match try_fold i rest with
      | Some m -> [ m ]
      | None -> rewrite_instr i :: rewrite_list rest)

and rewrite_desc (desc : location instr_desc) : location instr_desc =
  match desc with
  | Block { label; typ; block } ->
      Block { label; typ; block = rewrite_list block }
  | Loop { label; typ; block } ->
      Loop { label; typ; block = rewrite_list block }
  | While { label; cond; block } ->
      While { label; cond = rewrite_instr cond; block = rewrite_list block }
  | DoWhile { label; block; cond } ->
      DoWhile { label; block = rewrite_list block; cond = rewrite_instr cond }
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
  | Test (e, t) -> Test (rewrite_instr e, t)
  | NonNull e -> NonNull (rewrite_instr e)
  | Struct (idx, fs) ->
      Struct (idx, List.map (fun (n, e) -> (n, rewrite_instr e)) fs)
  | StructGet (e, x) -> StructGet (rewrite_instr e, x)
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
  | Br_table (ls, e) -> Br_table (ls, rewrite_instr e)
  | Br_on_null (l, e) -> Br_on_null (l, rewrite_instr e)
  | Br_on_non_null (l, e) -> Br_on_non_null (l, rewrite_instr e)
  | Br_on_cast (l, t, e) -> Br_on_cast (l, t, rewrite_instr e)
  | Br_on_cast_fail (l, t, e) -> Br_on_cast_fail (l, t, rewrite_instr e)
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
  | ( Unreachable | Nop | Hole | Null | Get _ | Char _ | String _ | Int _
    | Float _ | StructDefault _ ) as x ->
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
  | ( Type _ | Fundecl _ | GlobalDecl _ | Global _ | Tag _ | Memory _ | Data _
    | Table _ | Elem _ ) as f ->
      f

let module_ (m : location module_) : location module_ =
  List.map (fun a -> { a with desc = field_desc a.desc }) m
