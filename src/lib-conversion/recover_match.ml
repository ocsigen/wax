open Wax_lang
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
   [local.set] ([Set] / a fused [let]); {!Sink_let} sinks a local used across
   several arms to their common-ancestor ladder block, where it surfaces as a
   leading declaration. The fold hoists those out before the [match] (a
   declaration an arm rebinds is dropped instead, since re-lowering reintroduces
   it). A Wax [match] thus round-trips through the binary. Meant to run on
   {!Sink_let.module_} output.

   We also recover a [match] from the *flat* [br_on_cast_fail] chain that
   hand-written GC code more often uses — one discarded block per arm rather than
   the nested ladder; see {!collect_arms}. That round trip is not byte-for-byte
   (re-lowering emits the ladder), only semantically faithful. *)

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

(* Split off leading bare local declarations [let x;]. {!Sink_let} sinks a local
   used across several arms to their common-ancestor ladder block, where it shows
   up here as a leading declaration; the fold hoists those out before the match
   (they are *not* arm bindings — those are fused into the consume — so dropping
   them would unbind the local). Returns the declarations and the rest. *)
let split_decls stmts =
  let rec aux acc = function
    | ({ desc = Let ([ (Some _, _) ], None); _ } as d) :: rest ->
        aux (d :: acc) rest
    | rest -> (List.rev acc, rest)
  in
  aux [] stmts

(* Strip a ladder block's consume of its inner block, returning any leading
   declarations to hoist, the binding ([Some x] for a bound cast arm), that inner
   block, and the trailing arm body. A [null] arm consumes nothing (a bare
   block), an unbound cast drops the block (an anonymous [Let], [_ = block]), a
   bound cast binds it (a [Set] / a fused [let]). *)
let consume_step stmts =
  let decls, stmts = split_decls stmts in
  match stmts with
  | { desc = Let ([ (Some x, _) ], Some inner); _ } :: body when is_block inner
    ->
      Some (decls, Some x, inner, body)
  | { desc = Set (x, _, inner); _ } :: body when is_block inner ->
      Some (decls, Some x, inner, body)
  | { desc = Let ([ (None, _) ], Some inner); _ } :: body when is_block inner ->
      Some (decls, None, inner, body)
  | ({ desc = Block _; _ } as inner) :: body -> Some (decls, None, inner, body)
  | _ -> None

(* Descend the ladder from block [blk]. Returns the wrapper levels (outer→inner,
   one per arm: the block label, the arm's binding, and its body), the innermost
   block's label, the chain, the escape label, and the declarations to hoist. *)
let rec descend blk =
  match blk.desc with
  | Block { label = Some lbl; block = { desc = body; _ }; _ } -> (
      let decls0, body = split_decls body in
      match body with
      | [
       { desc = Let ([ (None, _) ], Some chain); _ };
       { desc = Br (escape, None); _ };
      ]
        when is_chain chain ->
          Some ([], lbl, chain, escape, decls0)
      | _ -> (
          match consume_step body with
          | Some (decls1, binding, inner, arm_body) -> (
              match descend inner with
              | Some (levels, inner_lbl, chain, escape, decls) ->
                  Some
                    ( (lbl, binding, arm_body) :: levels,
                      inner_lbl,
                      chain,
                      escape,
                      decls0 @ decls1 @ decls )
              | None -> None)
          | None -> None))
  | _ -> None

(* --- Flat [br_on_cast_fail] chain --------------------------------------- *)

(* Hand-written GC code (and pre-ladder Wax output) takes a value apart with a
   flat run of discarded blocks rather than the nested ladder {!descend} folds:

     _ = 'L: do S { let x = br_on_cast_fail 'L &T v; body }   (a bound cast arm)
     _ = 'L: do S { _ = br_on_cast_fail 'L &T v; body }       (an unbound cast arm)
     _ = 'L: do S { br_on_non_null 'L v; body }               (a null arm)

   Each block re-reads the same scrutinee [v] and, on a failed test, branches to
   its own label (forwarding [v], type [S]) and is dropped, falling through to
   the next block; on success the (optionally bound) narrowed value falls into
   [body], which diverges. So such a run is a [match] on [v], the trailing
   statements its default. Re-lowering a recovered match emits the nested ladder,
   not this flat chain, so the round trip is not byte-for-byte — but it is
   semantically equivalent (the scrutinee is side-effect-free, see
   {!same_scrut}). *)

(* Structural equality of scrutinee expressions, ignoring source locations: the
   side-effect-free forms a re-read scrutinee may take. Anything else compares
   unequal, so the run simply does not fold. *)
let rec same_scrut a b =
  match (a.desc, b.desc) with
  | Get x, Get y -> x.desc = y.desc
  | Null, Null -> true
  | Int s, Int t -> s = t
  | NonNull e, NonNull f -> same_scrut e f
  | Cast (e, s), Cast (f, t) -> s = t && same_scrut e f
  | Test (e, s), Test (f, t) -> s = t && same_scrut e f
  | StructGet (e, x), StructGet (f, y) -> x.desc = y.desc && same_scrut e f
  | ArrayGet (e, i), ArrayGet (f, j) -> same_scrut e f && same_scrut i j
  | _ -> false

(* Whether control cannot fall off the end of [body] — a conservative,
   syntactic check (the last statement is a clear terminator, or an [if]/[match]
   whose every branch diverges). A flat-chain arm is a genuine [match] arm only
   when its success path leaves the [match]; folding a non-diverging body (the
   block's [do S] result is produced and dropped instead) would be wrong. *)
let rec diverges_instr i =
  match i.desc with
  | Return _ | Br _ | Br_table _ | Unreachable | Throw _ | ThrowRef _
  | TailCall _ ->
      true
  | If { if_block; else_block = Some else_block; _ } ->
      diverges_list if_block.desc && diverges_list else_block.desc
  | Match { arms; default; _ } ->
      List.for_all (fun (_, b) -> diverges_list b.desc) arms
      && diverges_list default.desc
  | Loop { block; _ } ->
      (* A loop whose body always branches (back to the loop or out) never falls
         through to the statement after it. *)
      diverges_list block.desc
  | _ -> false

and diverges_list l =
  match List.rev l with [] -> false | last :: _ -> diverges_instr last

(* Recognise one flat-chain arm block. Returns its pattern, scrutinee, body, and
   whether a bound cast carries its binding itself (a fused [let x = …],
   [`Fused]) or names a local declared just before the block ([`Decl x], which
   the fold drops). The body must diverge (leave the [match]). *)
let arm_block stmt =
  match stmt.desc with
  | Let
      ( [ (None, _) ],
        Some
          {
            desc =
              Block
                { label = Some self; typ; block = { desc = test :: body; _ } };
            _;
          } )
    when typ.params = [||] && Array.length typ.results = 1 && diverges_list body
    -> (
      match test.desc with
      | Let ([ (Some x, _) ], Some { desc = Br_on_cast_fail (l, rt, scrut); _ })
        when l.desc = self.desc ->
          Some (MatchCast (Some x, rt), scrut, body, `Fused)
      | Set (x, _, { desc = Br_on_cast_fail (l, rt, scrut); _ })
        when l.desc = self.desc ->
          Some (MatchCast (Some x, rt), scrut, body, `Decl x)
      | Let ([ (None, _) ], Some { desc = Br_on_cast_fail (l, rt, scrut); _ })
        when l.desc = self.desc ->
          Some (MatchCast (None, rt), scrut, body, `Fused)
      | Br_on_non_null (l, scrut) when l.desc = self.desc ->
          Some (MatchNull, scrut, body, `Fused)
      | _ -> None)
  | _ -> None

let compat scrut s =
  match scrut with None -> true | Some s0 -> same_scrut s0 s

(* Collect a maximal run of flat-chain arms from the front of [stmts], threading
   the shared scrutinee. Returns the arms, the shared scrutinee, bare local
   declarations to hoist before the match, and the remaining (default)
   statements.

   A bare local declaration [let x;] between arms is either the binding for the
   next [`Decl]-form arm (dropped — the recovered arm re-declares it) or an
   unrelated local that {!Sink_let} floated into the run (hoisted before the
   match, where it stays in scope for every arm; this only fires when more arms
   follow, so a trailing declaration stays in the default). *)
let rec collect_arms scrut stmts =
  let take pat body s rest =
    let scrut = match scrut with None -> Some s | some -> some in
    let arms, scrut, hoisted, rest = collect_arms scrut rest in
    ((pat, body) :: arms, scrut, hoisted, rest)
  in
  match stmts with
  | ({ desc = Let ([ (Some x, _) ], None); _ } as decl) :: rest -> (
      match rest with
      | blk :: rest'
        when match arm_block blk with
             | Some (_, s, _, `Decl y) -> y.desc = x.desc && compat scrut s
             | _ -> false ->
          let pat, s, body =
            match arm_block blk with
            | Some (pat, s, body, _) -> (pat, s, body)
            | None -> assert false
          in
          take pat body s rest'
      | _ ->
          let arms, scrut, hoisted, trailing = collect_arms scrut rest in
          if arms = [] then ([], scrut, [], stmts)
          else (arms, scrut, decl :: hoisted, trailing))
  | blk :: rest -> (
      match arm_block blk with
      | Some (pat, s, body, `Fused) when compat scrut s -> take pat body s rest
      | _ -> ([], scrut, [], stmts))
  | [] -> ([], scrut, [], stmts)

let rec rewrite_instr (i : location instr) : location instr =
  { i with desc = rewrite_desc i.desc }

(* Fold the [escape] block [i] (and the trailing statements after it, which
   become the default) into a [match]. *)
and try_fold (i : location instr) (trailing : location instr list) :
    (location instr list * location instr) option =
  match descend i with
  | None -> None
  | Some (levels, inner_lbl, chain, escape, decls) ->
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
          Option.map (fun pat -> (pat, no_loc (rewrite_list body))) pat
        in
        let arms = List.map2 arm tests (List.rev levels) in
        if List.exists Option.is_none arms then None
        else
          let arms = List.filter_map Fun.id arms in
          (* A declaration whose name an arm rebinds is redundant (re-lowering
             reintroduces it); the rest are genuine locals to hoist. *)
          let bound =
            List.filter_map
              (fun (p, _) ->
                match p with MatchCast (Some x, _) -> Some x.desc | _ -> None)
              arms
          in
          let hoisted =
            List.filter
              (fun d ->
                match d.desc with
                | Let ([ (Some x, _) ], None) -> not (List.mem x.desc bound)
                | _ -> true)
              decls
          in
          Some
            ( hoisted,
              {
                i with
                desc =
                  Match
                    {
                      scrutinee = rewrite_instr scrut;
                      arms;
                      default = no_loc (rewrite_list trailing);
                    };
              } )

and rewrite_list stmts =
  match stmts with
  | [] -> []
  | i :: rest -> (
      (* First the nested ladder (the shape {!Ast_utils.lower_match} emits),
         then a flat [br_on_cast_fail] chain — folded even for a single arm (a
         lone downcast-or-branch reads as a one-arm [match]). *)
      match try_fold i rest with
      | Some (hoisted, m) -> List.map rewrite_instr hoisted @ [ m ]
      | None -> (
          match collect_arms None stmts with
          | (_ :: _ as arms), Some scrut, hoisted, trailing ->
              List.map rewrite_instr hoisted
              @ [
                  {
                    i with
                    desc =
                      Match
                        {
                          scrutinee = rewrite_instr scrut;
                          arms =
                            List.map
                              (fun (p, b) -> (p, no_loc (rewrite_list b)))
                              arms;
                          default = no_loc (rewrite_list trailing);
                        };
                  };
                ]
          | _ -> rewrite_instr i :: rewrite_list rest))

and rewrite_desc (desc : location instr_desc) : location instr_desc =
  match desc with
  | Block { label; typ; block } ->
      Block
        { label; typ; block = { block with desc = rewrite_list block.desc } }
  | Loop { label; typ; block } ->
      Loop { label; typ; block = { block with desc = rewrite_list block.desc } }
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
          catches =
            List.map
              (fun (t, l) -> (t, { l with desc = rewrite_list l.desc }))
              catches;
          catch_all =
            Option.map
              (fun b -> { b with desc = rewrite_list b.desc })
              catch_all;
        }
  | Dispatch { index; cases; default; arms } ->
      Dispatch
        {
          index = rewrite_instr index;
          cases;
          default;
          arms =
            List.map
              (fun (l, b) -> (l, { b with desc = rewrite_list b.desc }))
              arms;
        }
  | Match { scrutinee; arms; default } ->
      Match
        {
          scrutinee = rewrite_instr scrutinee;
          arms =
            List.map
              (fun (p, b) -> (p, { b with desc = rewrite_list b.desc }))
              arms;
          default = { default with desc = rewrite_list default.desc };
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
  | Labelled (l, e) -> Labelled (l, rewrite_instr e)
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
  | On (e, h) -> On (rewrite_instr e, h)
  | Br_table (ls, e) -> Br_table (ls, rewrite_instr e)
  | Br_on_null (l, e) -> Br_on_null (l, rewrite_instr e)
  | Br_on_non_null (l, e) -> Br_on_non_null (l, rewrite_instr e)
  | Br_on_cast (l, t, e) -> Br_on_cast (l, t, rewrite_instr e)
  | Br_on_cast_fail (l, t, e) -> Br_on_cast_fail (l, t, rewrite_instr e)
  | Br_on_cast_desc_eq (l, t, e, d) ->
      Br_on_cast_desc_eq (l, t, rewrite_instr e, rewrite_instr d)
  | Br_on_cast_desc_eq_fail (l, t, e, d) ->
      Br_on_cast_desc_eq_fail (l, t, rewrite_instr e, rewrite_instr d)
  | Throw (idx, e) -> Throw (idx, List.map rewrite_instr e)
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
