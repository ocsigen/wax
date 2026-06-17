open Wax
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
  | While { cond; block; _ } | DoWhile { block; cond; _ } ->
      occurs name cond || in_list block
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
  | Let (_, body) -> in_opt body
  | Br (_, o) | Throw (_, o) | Return o -> in_opt o
  | If_annotation { then_body; else_body; _ } -> (
      in_list then_body
      || match else_body with Some b -> in_list b | None -> false)
  | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _ | Float _
  | StructDefault _ ->
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

(* Try to push [decl] into a sub-scope of the single instruction [s] that holds
   all of its uses. Returns [None] when no inward move is possible (the caller
   then places a bare declaration before [s]). A [let] is forbidden inside an
   [If_annotation] branch, so those are never entered. *)
let rec sink_into ((name, _) as decl) s =
  let bl block = sink_decl decl block in
  match s.desc with
  | Block r -> Some { s with desc = Block { r with block = bl r.block } }
  | Loop r -> Some { s with desc = Loop { r with block = bl r.block } }
  | TryTable r -> Some { s with desc = TryTable { r with block = bl r.block } }
  | While r ->
      (* The test is evaluated in the enclosing scope (re-checked each
         iteration), so a use there pins the declaration outside the loop. *)
      if occurs name.desc r.cond then None
      else Some { s with desc = While { r with block = bl r.block } }
  | DoWhile r ->
      if occurs name.desc r.cond then None
      else Some { s with desc = DoWhile { r with block = bl r.block } }
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
  | Set (id, e)
    when match id with
         | Some n -> not (String.equal n.desc name.desc)
         | None -> true ->
      (* A discarded or assigned block expression — e.g. [_ = do {..}] or
         [x = do {..}] — holds all uses in its body; sink into it. We exclude
         [name = e]: there [e] is this local's own initializer (the non-reading
         case is already fused by [sink_decl]), and sinking the declaration into
         [e] would shadow it. *)
      Option.map (fun e' -> { s with desc = Set (id, e') }) (sink_into decl e)
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
