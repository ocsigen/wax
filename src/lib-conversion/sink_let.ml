open Wax_lang
open Ast

(* The only ways an instruction references a local are [Get], [Set] and [Tee];
   every other identifier (labels, tags, types, fields, functions...) lives in a
   different namespace, so we only treat those three as uses. The remaining
   cases simply recurse into sub-instructions. *)
let rec occurs name i =
  let in_list l = List.exists (occurs name) l in
  let in_opt o = match o with Some i -> occurs name i | None -> false in
  match i.desc with
  | Get id -> String.equal id.desc name
  | Tee (id, e) -> String.equal id.desc name || occurs name e
  | Set (id, e) ->
      (match id with Some id -> String.equal id.desc name | None -> false)
      || occurs name e
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      in_list block
  | While { cond; block; _ } -> occurs name cond || in_list block
  | If { cond; if_block; else_block; _ } -> (
      occurs name cond || in_list if_block.desc
      || match else_block with Some b -> in_list b.desc | None -> false)
  | Try { block; catches; catch_all; _ } -> (
      in_list block
      || List.exists (fun (_, b) -> in_list b) catches
      || match catch_all with Some b -> in_list b | None -> false)
  | Call (t, args) | TailCall (t, args) -> occurs name t || in_list args
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | StructDefaultDesc (_, e)
  | UnOp (_, e)
  | Br_if (_, e)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      occurs name e
  | Struct (_, fields) -> List.exists (fun (_, e) -> occurs name e) fields
  | StructDesc (_, d, fields) ->
      occurs name d || List.exists (fun (_, e) -> occurs name e) fields
  | CastDesc (e1, _, e2)
  | Br_on_cast_desc_eq (_, _, e1, e2)
  | Br_on_cast_desc_eq_fail (_, _, e1, e2)
  | StructSet (e1, _, e2)
  | Array (_, e1, e2)
  | ArraySegment (_, _, e1, e2)
  | ArrayGet (e1, e2)
  | BinOp (_, e1, e2) ->
      occurs name e1 || occurs name e2
  | ArraySet (e1, e2, e3) | Select (e1, e2, e3) ->
      occurs name e1 || occurs name e2 || occurs name e3
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Sequence l ->
      in_list l
  | Dispatch { index; arms; _ } ->
      occurs name index || List.exists (fun (_, b) -> in_list b) arms
  | Match { scrutinee; arms; default } ->
      occurs name scrutinee
      || List.exists (fun (_, b) -> in_list b) arms
      || in_list default
  | Let (_, body) -> in_opt body
  | Br (_, o) | Throw (_, o) | Return o -> in_opt o
  | If_annotation { then_body; else_body; _ } -> (
      in_list then_body
      || match else_body with Some b -> in_list b | None -> false)
  | Path _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      false

let list_occurs name l = List.exists (occurs name) l
let bare_let (name, typ) = no_loc (Let ([ (Some name, Some typ) ], None))

let init_let (name, typ) e info =
  { desc = Let ([ (Some name, Some typ) ], Some e); info }

(* [name = e] is fusable into [let name = e] only when the assignment is the
   first use of [name] (the caller guarantees that) and [e] does not read
   [name] itself: [let name = e] does not bring [name] into scope within [e],
   and a bare declaration zero-initializes the local, so refusing here keeps the
   read-before-write behaviour intact. *)
let fusable s name =
  match s.desc with
  | Set (Some id, e) when String.equal id.desc name && not (occurs name e) ->
      Some e
  | _ -> None

let rec split_around i l =
  match l with
  | x :: r ->
      if i = 0 then ([], x, r)
      else
        let prefix, s, suffix = split_around (i - 1) r in
        (x :: prefix, s, suffix)
  | [] -> assert false

let first_use_index name l =
  let rec aux i = function
    | [] -> None
    | x :: r -> if occurs name x then Some i else aux (i + 1) r
  in
  aux 0 l

(* The kind of the first access to [name] within [i], in execution order:
   [`Read] if the local is read before any assignment to it, [`Write] if it is
   assigned first, [None] if [i] does not touch it. For [Set]/[Tee] the value is
   evaluated before the binding, so a self-reference there is a read seen first.
   Conditional sub-scopes (the branches of an [If]/[If_annotation], catch
   handlers, dispatch arms) are runtime-dependent: we commit to a kind only when
   the alternatives agree, otherwise report [None] so a later instruction — or,
   failing that, "not read first" — decides. *)
let rec first_access name i =
  let fst2 a b = match a with Some _ -> a | None -> b in
  let fl l = first_access_list name l in
  let fo = function Some e -> first_access name e | None -> None in
  let agree a b =
    match (a, b) with Some x, Some y when x = y -> Some x | _ -> None
  in
  match i.desc with
  | Get id -> if String.equal id.desc name then Some `Read else None
  | Tee (id, e) ->
      fst2 (first_access name e)
        (if String.equal id.desc name then Some `Write else None)
  | Set (id, e) ->
      fst2 (first_access name e)
        (match id with
        | Some id when String.equal id.desc name -> Some `Write
        | _ -> None)
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } -> fl block
  | While { cond; block; _ } -> fst2 (first_access name cond) (fl block)
  | If { cond; if_block; else_block; _ } ->
      fst2 (first_access name cond)
        (agree (fl if_block.desc)
           (match else_block with Some b -> fl b.desc | None -> None))
  | Try { block; catches; catch_all; _ } ->
      fst2 (fl block)
        (List.fold_left
           (fun acc (_, b) -> agree acc (fl b))
           (match catch_all with Some b -> fl b | None -> None)
           catches)
  | Call (t, args) | TailCall (t, args) -> fst2 (fl args) (first_access name t)
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | StructDefaultDesc (_, e)
  | UnOp (_, e)
  | Br_if (_, e)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      first_access name e
  | Struct (_, fields) -> fl (List.map snd fields)
  | StructDesc (_, d, fields) ->
      (* The field values are evaluated before the descriptor operand. *)
      fst2 (fl (List.map snd fields)) (first_access name d)
  | CastDesc (e1, _, e2)
  | Br_on_cast_desc_eq (_, _, e1, e2)
  | Br_on_cast_desc_eq_fail (_, _, e1, e2)
  | StructSet (e1, _, e2)
  | Array (_, e1, e2)
  | ArraySegment (_, _, e1, e2)
  | ArrayGet (e1, e2)
  | BinOp (_, e1, e2) ->
      fst2 (first_access name e1) (first_access name e2)
  | ArraySet (e1, e2, e3) | Select (e1, e2, e3) ->
      fst2 (first_access name e1)
        (fst2 (first_access name e2) (first_access name e3))
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Sequence l ->
      fl l
  | Dispatch { index; arms; _ } ->
      fst2 (first_access name index)
        (List.fold_left (fun acc (_, b) -> agree acc (fl b)) None arms)
  | Match { scrutinee; arms; default } ->
      (* The scrutinee is evaluated first; the arms and default are the
         (mutually exclusive) runtime-dependent alternatives, so commit only
         when they agree. *)
      fst2
        (first_access name scrutinee)
        (List.fold_left (fun acc (_, b) -> agree acc (fl b)) (fl default) arms)
  | Let (_, body) -> fo body
  | Br (_, o) | Throw (_, o) | Return o -> fo o
  | If_annotation { then_body; else_body; _ } ->
      agree (fl then_body)
        (match else_body with Some b -> fl b | None -> None)
  | Path _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      None

and first_access_list name l =
  List.fold_left
    (fun acc i -> match acc with Some _ -> acc | None -> first_access name i)
    None l

(* A loop / while body runs many times, so a local the body reads
   before assigning carries its value across iterations and belongs in the
   enclosing scope, not the body. A local written before it is ever read is a
   fresh per-iteration temporary and is left to sink in (and fuse with its
   initializer). *)
let loop_carried name l = first_access_list name l = Some `Read

(* Try to push [decl] into a sub-scope of the single instruction [s] that holds
   all of its uses. Returns [None] when no inward move is possible (the caller
   then places a bare declaration before [s]). A [let] is forbidden inside an
   [If_annotation] branch, so those are never entered. *)
let rec sink_into ((name, _) as decl) s =
  let bl block = sink_decl decl block in
  let occ e = occurs name.desc e in
  (* Recurse into the unique sub-expression of [s] holding every use of the
     local and rebuild [s] around the result. With all uses in one operand no
     sibling reads the local, so their evaluation order is irrelevant; uses
     split across operands, or an operand with no inner block to take the let,
     yield [None] and leave a bare declaration before [s]. *)
  let pick children =
    match List.filter (fun (e, _) -> occ e) children with
    | [ (e, mk) ] ->
        Option.map (fun e' -> { s with desc = mk e' }) (sink_into decl e)
    | _ -> None
  in
  (* The [pick] children for an operand list: each element paired with the
     rebuild that reinstalls it. *)
  let in_list l mk =
    List.mapi
      (fun i e ->
        (e, fun e' -> mk (List.mapi (fun j x -> if i = j then e' else x) l)))
      l
  in
  match s.desc with
  | Block r -> Some { s with desc = Block { r with block = bl r.block } }
  | Loop r ->
      (* A loop re-enters its body, so a value carried across iterations pins
         the declaration outside it (see [loop_carried]). *)
      if loop_carried name.desc r.block then None
      else Some { s with desc = Loop { r with block = bl r.block } }
  | TryTable r -> Some { s with desc = TryTable { r with block = bl r.block } }
  | While r ->
      (* The test is evaluated in the enclosing scope (re-checked each
         iteration), so a use there pins the declaration outside the loop; so
         does a value the body carries across iterations. *)
      if occurs name.desc r.cond || loop_carried name.desc r.block then None
      else Some { s with desc = While { r with block = bl r.block } }
  | If r ->
      (* The condition is evaluated in the enclosing scope, so a use there
         pins the declaration outside the [If]; a use in both branches cannot
         be covered by a single declaration. *)
      if occurs name.desc r.cond then None
      else
        let in_then = list_occurs name.desc r.if_block.desc in
        let in_else =
          match r.else_block with
          | Some b -> list_occurs name.desc b.desc
          | None -> false
        in
        if in_then && not in_else then
          Some
            {
              s with
              desc =
                If
                  {
                    r with
                    if_block = { r.if_block with desc = bl r.if_block.desc };
                  };
            }
        else if in_else && not in_then then
          Some
            {
              s with
              desc =
                If
                  {
                    r with
                    else_block =
                      Option.map
                        (fun b -> { b with desc = bl b.desc })
                        r.else_block;
                  };
            }
        else None
  | Try r ->
      let in_block = list_occurs name.desc r.block in
      let n_catches =
        List.length
          (List.filter (fun (_, b) -> list_occurs name.desc b) r.catches)
      in
      let in_all =
        match r.catch_all with
        | Some b -> list_occurs name.desc b
        | None -> false
      in
      let count =
        (if in_block then 1 else 0) + n_catches + if in_all then 1 else 0
      in
      if count <> 1 then None
      else if in_block then
        Some { s with desc = Try { r with block = bl r.block } }
      else if in_all then
        Some
          { s with desc = Try { r with catch_all = Option.map bl r.catch_all } }
      else
        let catches =
          List.map
            (fun (tag, b) ->
              if list_occurs name.desc b then (tag, bl b) else (tag, b))
            r.catches
        in
        Some { s with desc = Try { r with catches } }
  | Dispatch r ->
      (* The index is evaluated in the enclosing scope, so a use there pins the
         declaration outside; the arms are mutually exclusive, so a single
         declaration can cover at most one. *)
      if occ r.index then None
      else if
        List.length (List.filter (fun (_, b) -> list_occurs name.desc b) r.arms)
        <> 1
      then None
      else
        let arms =
          List.map
            (fun (l, b) ->
              if list_occurs name.desc b then (l, bl b) else (l, b))
            r.arms
        in
        Some { s with desc = Dispatch { r with arms } }
  (* Expression carriers: descend through an operand toward a nested block. *)
  | Set (id, e)
    when match id with
         | Some n -> not (String.equal n.desc name.desc)
         | None -> true ->
      (* A discarded or assigned block expression — e.g. [_ = do {..}] or
         [x = do {..}] — holds all uses in its body; sink into it. We exclude
         [name = e]: there [e] is this local's own initializer (the non-reading
         case is already fused by [sink_decl]), and sinking the declaration into
         [e] would shadow it. *)
      pick [ (e, fun e' -> Set (id, e')) ]
  | Tee (n, e) when not (String.equal n.desc name.desc) ->
      pick [ (e, fun e' -> Tee (n, e')) ]
  | Let (bindings, Some e)
    when not
           (List.exists
              (fun (id, _) ->
                match id with
                | Some n -> String.equal n.desc name.desc
                | None -> false)
              bindings) ->
      (* [let y = <block>] (binding some other local) holds every use of [name]
         in its initializer; descend into it, as for [Set]. The initializer is
         evaluated before [y] enters scope, so placing the declaration inside it
         does not shadow [name]. *)
      pick [ (e, fun e' -> Let (bindings, Some e')) ]
  | Call (t, args) ->
      pick
        ((t, fun t' -> Call (t', args))
        :: in_list args (fun args' -> Call (t, args')))
  | TailCall (t, args) ->
      pick
        ((t, fun t' -> TailCall (t', args))
        :: in_list args (fun args' -> TailCall (t, args')))
  | BinOp (op, a, b) ->
      pick
        [ (a, fun a' -> BinOp (op, a', b)); (b, fun b' -> BinOp (op, a, b')) ]
  | ArrayGet (a, b) ->
      pick [ (a, fun a' -> ArrayGet (a', b)); (b, fun b' -> ArrayGet (a, b')) ]
  | Array (idx, a, b) ->
      pick
        [ (a, fun a' -> Array (idx, a', b)); (b, fun b' -> Array (idx, a, b')) ]
  | ArraySegment (idx, d, a, b) ->
      pick
        [
          (a, fun a' -> ArraySegment (idx, d, a', b));
          (b, fun b' -> ArraySegment (idx, d, a, b'));
        ]
  | StructSet (a, f, b) ->
      pick
        [
          (a, fun a' -> StructSet (a', f, b));
          (b, fun b' -> StructSet (a, f, b'));
        ]
  | ArraySet (a, b, c) ->
      pick
        [
          (a, fun a' -> ArraySet (a', b, c));
          (b, fun b' -> ArraySet (a, b', c));
          (c, fun c' -> ArraySet (a, b, c'));
        ]
  | Select (a, b, c) ->
      pick
        [
          (a, fun a' -> Select (a', b, c));
          (b, fun b' -> Select (a, b', c));
          (c, fun c' -> Select (a, b, c'));
        ]
  | Struct (idx, fields) ->
      pick
        (List.mapi
           (fun i (_, e) ->
             ( e,
               fun e' ->
                 Struct
                   ( idx,
                     List.mapi
                       (fun j (fn, x) -> (fn, if i = j then e' else x))
                       fields ) ))
           fields)
  | Cast (e, t) -> pick [ (e, fun e' -> Cast (e', t)) ]
  | Test (e, t) -> pick [ (e, fun e' -> Test (e', t)) ]
  | NonNull e -> pick [ (e, fun e' -> NonNull e') ]
  | StructGet (e, f) -> pick [ (e, fun e' -> StructGet (e', f)) ]
  | UnOp (op, e) -> pick [ (e, fun e' -> UnOp (op, e')) ]
  | ThrowRef e -> pick [ (e, fun e' -> ThrowRef e') ]
  | ArrayDefault (idx, e) -> pick [ (e, fun e' -> ArrayDefault (idx, e')) ]
  | ContNew (ct, e) -> pick [ (e, fun e' -> ContNew (ct, e')) ]
  | Br_if (l, e) -> pick [ (e, fun e' -> Br_if (l, e')) ]
  | Br_table (ls, e) -> pick [ (e, fun e' -> Br_table (ls, e')) ]
  | Br_on_null (l, e) -> pick [ (e, fun e' -> Br_on_null (l, e')) ]
  | Br_on_non_null (l, e) -> pick [ (e, fun e' -> Br_on_non_null (l, e')) ]
  | Br_on_cast (l, t, e) -> pick [ (e, fun e' -> Br_on_cast (l, t, e')) ]
  | Br_on_cast_fail (l, t, e) ->
      pick [ (e, fun e' -> Br_on_cast_fail (l, t, e')) ]
  | Br (l, Some e) -> pick [ (e, fun e' -> Br (l, Some e')) ]
  | Return (Some e) -> pick [ (e, fun e' -> Return (Some e')) ]
  | Throw (idx, Some e) -> pick [ (e, fun e' -> Throw (idx, Some e')) ]
  | ArrayFixed (idx, l) -> pick (in_list l (fun l' -> ArrayFixed (idx, l')))
  | ContBind (a, b, l) -> pick (in_list l (fun l' -> ContBind (a, b, l')))
  | Suspend (tag, l) -> pick (in_list l (fun l' -> Suspend (tag, l')))
  | Resume (ct, h, l) -> pick (in_list l (fun l' -> Resume (ct, h, l')))
  | ResumeThrow (ct, tag, h, l) ->
      pick (in_list l (fun l' -> ResumeThrow (ct, tag, h, l')))
  | ResumeThrowRef (ct, h, l) ->
      pick (in_list l (fun l' -> ResumeThrowRef (ct, h, l')))
  | Switch (ct, tag, l) -> pick (in_list l (fun l' -> Switch (ct, tag, l')))
  | Sequence l -> pick (in_list l (fun l' -> Sequence l'))
  | _ -> None

(* Place a single declaration into [l]. Precondition: every use of the local
   lies within [l], and nothing before [l] uses it. *)
and sink_decl ((name, _) as decl) l =
  match first_use_index name.desc l with
  | None -> bare_let decl :: l
  | Some i -> (
      let prefix, s, suffix = split_around i l in
      match fusable s name.desc with
      | Some e -> prefix @ (init_let decl e s.info :: suffix)
      | None -> (
          if list_occurs name.desc suffix then
            prefix @ (bare_let decl :: s :: suffix)
          else
            match sink_into decl s with
            | Some s' -> prefix @ (s' :: suffix)
            | None -> prefix @ (bare_let decl :: s :: suffix)))

let rec extract_leading_decls acc instrs =
  match instrs with
  | { desc = Let ([ (Some name, Some typ) ], None); _ } :: rest ->
      extract_leading_decls ((name, typ) :: acc) rest
  | _ -> (List.rev acc, instrs)

let process_body instrs =
  let decls, rest = extract_leading_decls [] instrs in
  (* An unused declaration has no sink target, so [sink_decl] just prepends it.
     Folding such declarations would reverse their order on each pass (and
     [Sink_let] runs on every conversion to Wax), so the round-trip would never
     settle. Place the used ones via the fold, then prepend the unused ones in
     their original order so the output is a fixpoint. *)
  let used, unused =
    List.partition (fun (name, _) -> list_occurs name.desc rest) decls
  in
  let body = List.fold_left (fun acc decl -> sink_decl decl acc) rest used in
  List.fold_right (fun decl acc -> bare_let decl :: acc) unused body

let rec field_desc (f : location modulefield) =
  let map_fields = List.map (fun a -> { a with desc = field_desc a.desc }) in
  match f with
  | Func ({ body = label, instrs; _ } as r) ->
      Func { r with body = (label, process_body instrs) }
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
