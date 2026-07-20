open Wax_lang
open Ast

(* Recover a structured [try] from the [try_table]-plus-block-ladder shape that
   [Ast_utils.lower_trycatch] emits (and that compilers targeting [try_table]
   conventionally use): a [join] block wrapping one block per arm (the first
   arm innermost), the [try_table] innermost — its value escaping with a
   [br 'join] — one catch clause per arm branching to that arm's block, and
   each arm body as the trailing code just after its block:

     'join: { 'a2: { 'a1: { br 'join (try { body } catch [t1 -> 'a1, t2 -> 'a2]) } b1 } b2 }
     ⇒ 'join: try { body } catch { t1 => { b1 } t2 => { b2 } }

   Arms need not end in a branch: a fall-through arm (its completion feeding
   the next arm's entry, or the join) and a trailing-diverging arm recover
   directly. Folding is the exact inverse of the lowering — re-lowering
   reproduces the original blocks — so it preserves runtime semantics; the
   matcher confirms the shape:

   - the catch clauses target the ladder labels in order, innermost first, one
     clause per ladder block, and nothing else targets them (the arm labels
     have no surface spelling);
   - a catch-all clause only appears last (the grammar puts the [_] arm last);
   - the [try_table]'s own label, if any, is untargeted (a branch to it has no
     structured equivalent);
   - every block is parameterless.

   The recovered try keeps the join label only when the bodies still target it
   (the explicit-escape idiom [br 'join v]); otherwise it is dropped, so a
   label-less source try round-trips identically. Ladders that do not conform
   are left as-is: the bracket form ([try { … } catch [t -> 'l]]) remains the
   fallback spelling. *)

let no_params (t : functype) = t.params = [||]

(* Labels an instruction *targets* (not defines): the shape check requires the
   ladder labels to be reachable only through the [try_table]'s catch clauses.
   Shadowing by an inner definition is ignored — a shadowed use only makes the
   check conservatively bail. *)
let target_labels (desc : location instr_desc) : label list =
  match desc with
  | Br (l, _)
  | Br_if (l, _)
  | Br_on_null (l, _)
  | Br_on_non_null (l, _)
  | Br_on_cast (l, _, _)
  | Br_on_cast_fail (l, _, _)
  | Br_on_cast_desc_eq (l, _, _, _)
  | Br_on_cast_desc_eq_fail (l, _, _, _) ->
      [ l ]
  | Br_table (ls, _) -> ls
  | Dispatch { cases; default; _ } -> cases @ [ default ]
  | TryTable { catches; _ } ->
      List.map
        (function
          | Catch (_, l) | CatchRef (_, l) | CatchAll l | CatchAllRef l -> l)
        catches
  | Resume (_, hs, _)
  | ResumeThrow (_, _, hs, _)
  | ResumeThrowRef (_, hs, _)
  | On (_, hs) ->
      List.filter_map
        (function OnLabel (_, l) -> Some l | OnSwitch _ -> None)
        hs
  | _ -> []

let targets name instrs =
  let found = ref false in
  List.iter
    (Ast_utils.iter_instr (fun i ->
         if
           List.exists (fun (l : label) -> l.desc = name) (target_labels i.desc)
         then found := true))
    instrs;
  !found

(* When the first statement of a peel level embeds the next ladder block as
   its first-evaluated operand — [From_wasm] merges a produced value into its
   consumer, so [wrap(block)], [_ = block], [br 'j block] — extract it: return
   the block's pieces and the statement with the block replaced by a hole,
   which is how the source arm spells the payload pickup. Extraction only
   descends along positions [To_wasm] evaluates first (so the hole stays the
   first value the statement pulls from the stack): a call's first argument
   only for a plain named-function callee — a method receiver or indirect call
   evaluates differently, and any unrecognized consumer just leaves the ladder
   to the bracket-form fallback. *)
let rec extract_first_block (i : location instr) =
  let sub e rebuild =
    Option.map
      (fun (l, t, inner, e') -> (l, t, inner, { i with desc = rebuild e' }))
      (extract_first_block e)
  in
  match i.desc with
  | Block { label = Some l; typ; block = { desc = inner; _ } } ->
      Some (l, typ, inner, { i with desc = Hole })
  | Let (pats, Some e) -> sub e (fun e' -> Let (pats, Some e'))
  | Br (lb, Some e) -> sub e (fun e' -> Br (lb, Some e'))
  | Br_if (lb, e) -> sub e (fun e' -> Br_if (lb, e'))
  | Br_table (ls, e) -> sub e (fun e' -> Br_table (ls, e'))
  | Return (Some e) -> sub e (fun e' -> Return (Some e'))
  | Set (x, op, e) -> sub e (fun e' -> Set (x, op, e'))
  | Tee (x, e) -> sub e (fun e' -> Tee (x, e'))
  | Cast (e, ty) -> sub e (fun e' -> Cast (e', ty))
  | Test (e, ty) -> sub e (fun e' -> Test (e', ty))
  | NonNull e -> sub e (fun e' -> NonNull e')
  | StructGet (e, f) -> sub e (fun e' -> StructGet (e', f))
  | GetDescriptor e -> sub e (fun e' -> GetDescriptor e')
  | UnOp (op, e) -> sub e (fun e' -> UnOp (op, e'))
  | BinOp (op, a, b) -> sub a (fun a' -> BinOp (op, a', b))
  | ThrowRef e -> sub e (fun e' -> ThrowRef e')
  | Throw (t, a :: args) -> sub a (fun a' -> Throw (t, a' :: args))
  | Call (({ desc = Get _; _ } as f), a :: args) ->
      sub a (fun a' -> Call (f, a' :: args))
  | TailCall (({ desc = Get _; _ } as f), a :: args) ->
      sub a (fun a' -> TailCall (f, a' :: args))
  | _ -> None

(* Peel the arm-block ladder inside the join block: collect each ladder
   block's (label, result types, trailing body), outermost first, down to the
   innermost content — the [try_table] escaping to [join]. A ladder block is
   either the leading statement of its level or embedded in that statement as
   its first-evaluated operand (see {!extract_first_block}). *)
let rec descend join block =
  match block with
  | [
   {
     desc =
       Br
         ( (j : label),
           Some { desc = TryTable { label = None; typ; catches; block }; _ } );
     _;
   };
  ]
    when j.desc = join && no_params typ && typ.results <> [||] ->
      Some ([], typ, catches, block)
  | [
   { desc = TryTable { label = None; typ; catches; block }; _ };
   { desc = Br ((j : label), None); _ };
  ]
    when j.desc = join && no_params typ && typ.results = [||] ->
      Some ([], typ, catches, block)
  | { desc = Block { label = Some l; typ; block = { desc = inner; _ } }; _ }
    :: body
    when no_params typ -> (
      match descend join inner with
      | Some (arms, ttyp, catches, tbody) ->
          Some ((l, typ.results, body) :: arms, ttyp, catches, tbody)
      | None -> None)
  | first :: body -> (
      match extract_first_block first with
      | Some (l, typ, inner, first') when no_params typ -> (
          match descend join inner with
          | Some (arms, ttyp, catches, tbody) ->
              Some
                ((l, typ.results, first' :: body) :: arms, ttyp, catches, tbody)
          | None -> None)
      | _ -> None)
  | [] -> None

(* Recurse into children structurally. *)
let rec rewrite_instr (i : location instr) : location instr =
  match try_fold i with
  | Some folded -> folded
  | None ->
      let d = rewrite_desc i.desc in
      if d == i.desc then i else { i with desc = d }

and rewrite_list l = Ast_utils.smart_map rewrite_instr l

and try_fold (i : location instr) : location instr option =
  match i.desc with
  | Block { label = Some join; typ; block } when no_params typ -> (
      match descend join.desc block.desc with
      | Some (rev_arms, ttyp, catches, tbody) when catches <> [] -> (
          (* Ladder blocks come out outermost first; catch clauses are in arm
             order (innermost first). *)
          let blocks = List.rev rev_arms in
          if List.length blocks <> List.length catches then None
          else if
            not (Array.length ttyp.results = Array.length typ.results)
            (* The try_table's result type is the join's (the escaping [br]
               carries it); a mismatch is not our shape. *)
          then None
          else
            let arm (catch : catch) ((l : label), types, body) =
              let tag, ref_, target =
                match catch with
                | Catch (t, tl) -> (Some t, false, tl)
                | CatchRef (t, tl) -> (Some t, true, tl)
                | CatchAll tl -> (None, false, tl)
                | CatchAllRef tl -> (None, true, tl)
              in
              if target.desc <> l.desc then None
              else
                Some
                  {
                    arm_tag = tag;
                    arm_ref = ref_;
                    arm_types = types;
                    arm_body = no_loc body;
                  }
            in
            let rec build catches blocks =
              match (catches, blocks) with
              | [], [] -> Some []
              | c :: cs, b :: bs -> (
                  match (arm c b, build cs bs) with
                  | Some a, Some rest -> Some (a :: rest)
                  | _ -> None)
              | _ -> None
            in
            match build catches blocks with
            | Some arms
              when (* the catch-all is grammar-enforced last *)
                   List.for_all
                     (fun a -> a.arm_tag <> None)
                     (match List.rev arms with
                     | [] -> []
                     | _ :: init_rev -> init_rev)
                   (* nothing but its catch clause may target a ladder label *)
                   && (let all_bodies =
                         tbody.desc
                         @ List.concat_map (fun a -> a.arm_body.desc) arms
                       in
                       List.for_all
                         (fun ((l : label), _, _) ->
                           not (targets l.desc all_bodies))
                         blocks)
                   (* arm labels are distinct (a shared label would alias) *)
                   &&
                   let names =
                     List.map (fun ((l : label), _, _) -> l.desc) blocks
                   in
                   List.length (List.sort_uniq compare names)
                   = List.length names ->
                let all_bodies =
                  tbody.desc @ List.concat_map (fun a -> a.arm_body.desc) arms
                in
                let label =
                  if targets join.desc all_bodies then Some join else None
                in
                Some
                  {
                    i with
                    desc =
                      TryCatch
                        {
                          label;
                          typ;
                          block = { tbody with desc = rewrite_list tbody.desc };
                          arms =
                            List.map
                              (fun a ->
                                {
                                  a with
                                  arm_body =
                                    {
                                      a.arm_body with
                                      desc = rewrite_list a.arm_body.desc;
                                    };
                                })
                              arms;
                        };
                  }
            | _ -> None)
      | _ -> None)
  | _ -> None

and rewrite_desc (desc : location instr_desc) : location instr_desc =
  (* Purely structural recursion; the folding lives in [try_fold]/[rewrite_list].
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
