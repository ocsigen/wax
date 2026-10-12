module Uint32 = Wax_utils.Uint32
module StringMap = Map.Make (String)
open Ast.Text

let error ?hint d ~location message =
  Wax_utils.Diagnostic.report d ~location ~severity:Error
    ~message:(Wax_utils.Message.text message)
    ?hint:(Option.map Wax_utils.Message.text hint)
    ();
  Wax_utils.Diagnostic.abort ()

(*** Index spaces ***)

(* The definitions of one index space, in index order. A conditional
   annotation's branches are both registered, as {!Folding} does: a name declared
   in several branches has several candidates, which {!resolve} accepts when they
   agree on what the rewrite needs. *)
type 'a space = {
  kind : string;
  by_index : 'a array;
  by_name : 'a list StringMap.t;
}

let space kind entries =
  {
    kind;
    by_index = Array.of_list (List.map snd entries);
    by_name =
      List.fold_left
        (fun m (id, v) ->
          match id with
          | None -> m
          | Some id ->
              StringMap.update id.Ast.desc
                (fun l -> Some (v :: Option.value ~default:[] l))
                m)
        StringMap.empty entries;
  }

let resolve d sp ~get ~eq (idx : idx) =
  let unbound () =
    error d ~location:idx.info (Printf.sprintf "This %s is unbound." sp.kind)
  in
  match idx.desc with
  | Num n ->
      let n = Uint32.to_int n in
      if n < 0 || n >= Array.length sp.by_index then unbound ()
      else get sp.by_index.(n)
  | Id s -> (
      match StringMap.find_opt s sp.by_name with
      | None | Some [] -> unbound ()
      | Some (v :: rest) ->
          let r = get v in
          if List.for_all (fun v' -> eq r (get v')) rest then r
          else
            error d ~location:idx.info
              ~hint:"Resolve the conditionals with -D/--define."
              (Printf.sprintf
                 "This %s is declared differently in the branches of a \
                  conditional annotation."
                 sp.kind))

(* The module's fields with conditional annotations and compact import groups
   flattened out. *)
let rec flatten_fields fields =
  List.concat_map
    (fun (f : (_ modulefield, _) Ast.annotated) ->
      match f.desc with
      | Module_if_annotation { then_fields; else_fields; _ } ->
          flatten_fields then_fields.desc
          @ Option.fold ~none:[]
              ~some:(fun e -> flatten_fields e.Ast.desc)
              else_fields
      | Import_group1 _ | Import_group2 _ -> Ast_utils.expand_import_group f
      | _ -> [ f ])
    fields

type env = {
  d : Wax_utils.Diagnostic.context;
  types : subtype space;
  tags : typeuse space;
}

let module_env d fields =
  let fields = flatten_fields fields in
  {
    d;
    types =
      space "type"
        (List.concat_map
           (fun (f : (_ modulefield, _) Ast.annotated) ->
             match f.desc with
             | Types l -> Array.to_list (Array.map (fun e -> e.Ast.desc) l)
             | _ -> [])
           fields);
    tags =
      space "tag"
        (List.filter_map
           (fun (f : (_ modulefield, _) Ast.annotated) ->
             match f.desc with
             | Tag { id; typ; _ } | Import { id; desc = Tag typ; _ } ->
                 Some (id, typ)
             | _ -> None)
           fields);
  }

(* Type equality up to locations: two declarations of the same name are
   interchangeable when they agree on this. *)
let heaptype_eq (a : heaptype) (b : heaptype) =
  match (a, b) with
  | Type i, Type j | Exact i, Exact j -> i.desc = j.desc
  | (Type _ | Exact _), _ | _, (Type _ | Exact _) -> false
  | _ -> a = b

let valtype_eq (a : valtype) (b : valtype) =
  match (a, b) with
  | Ref r, Ref r' -> r.nullable = r'.nullable && heaptype_eq r.typ r'.typ
  | Ref _, _ | _, Ref _ -> false
  | _ -> a = b

let valtypes_eq a b =
  Array.length a = Array.length b && Array.for_all2 valtype_eq a b

let param_types (ft : functype) = Array.map (fun p -> snd p.Ast.desc) ft.params

let functype_eq a b =
  valtypes_eq (param_types a) (param_types b) && valtypes_eq a.results b.results

let type_functype env (idx : idx) =
  resolve env.d env.types ~eq:functype_eq idx ~get:(fun (st : subtype) ->
      match st.typ with
      | Func ft -> ft
      | Struct _ | Array _ | Cont _ ->
          error env.d ~location:idx.info "This type should be a function type.")

let typeuse_functype env ((i, ft) : typeuse) =
  match (i, ft) with
  | _, Some ft -> ft
  | Some i, None -> type_functype env i
  | None, None -> assert false

(* The payload a [catch] of tag [tag] delivers. *)
let tag_payload env tag =
  resolve env.d env.tags ~eq:valtypes_eq tag ~get:(fun typ ->
      param_types (typeuse_functype env typ))

(*** Label depths ***)

(* [shift_instrs ~depth ~by l] adds [by] to every numeric label index of [l]
   that refers past [depth] enclosing labels — a label bound outside [l] — to
   account for [by] blocks inserted between [l] and those labels. Named labels
   are left alone: the inserted blocks are unnamed. *)
let shift_label ~depth ~by (l : idx) =
  match l.desc with
  | Num n when Uint32.to_int n >= depth ->
      { l with desc = Num (Uint32.of_int (Uint32.to_int n + by)) }
  | Num _ | Id _ -> l

let rec shift_instr ~depth ~by (i : _ instr) =
  let label = shift_label ~depth ~by in
  let body ~depth (b : (_ instr list, _) Ast.annotated) =
    { b with desc = shift_instrs ~depth ~by b.desc }
  in
  let inner = body ~depth:(depth + 1) in
  let on_clause = function
    | OnLabel (tag, l) -> OnLabel (tag, label l)
    | OnSwitch _ as c -> c
  in
  let desc =
    match i.desc with
    | Block b -> Block { b with block = inner b.block }
    | Loop b -> Loop { b with block = inner b.block }
    | If b ->
        If
          {
            b with
            if_block = inner b.if_block;
            else_block = inner b.else_block;
          }
    | TryTable b ->
        (* The catch clauses are resolved outside the [try_table]'s label. *)
        TryTable
          {
            b with
            block = inner b.block;
            catches =
              List.map
                (function
                  | Catch (tag, l) -> Catch (tag, label l)
                  | CatchRef (tag, l) -> CatchRef (tag, label l)
                  | CatchAll l -> CatchAll (label l)
                  | CatchAllRef l -> CatchAllRef (label l))
                b.catches;
          }
    | Try b ->
        Try
          {
            b with
            block = inner b.block;
            catches = List.map (fun (tag, h) -> (tag, inner h)) b.catches;
            catch_all = Option.map inner b.catch_all;
          }
    | Br l -> Br (label l)
    | Br_if l -> Br_if (label l)
    | Br_table (ls, l) -> Br_table (List.map label ls, label l)
    | Br_on_null l -> Br_on_null (label l)
    | Br_on_non_null l -> Br_on_non_null (label l)
    | Br_on_cast (l, t, t') -> Br_on_cast (label l, t, t')
    | Br_on_cast_fail (l, t, t') -> Br_on_cast_fail (label l, t, t')
    | Br_on_cast_desc_eq (l, t, t') -> Br_on_cast_desc_eq (label l, t, t')
    | Br_on_cast_desc_eq_fail (l, t, t') ->
        Br_on_cast_desc_eq_fail (label l, t, t')
    | Resume (t, cl) -> Resume (t, List.map on_clause cl)
    | ResumeThrow (t, x, cl) -> ResumeThrow (t, x, List.map on_clause cl)
    | ResumeThrowRef (t, cl) -> ResumeThrowRef (t, List.map on_clause cl)
    | Folded (h, args) ->
        Folded (shift_instr ~depth ~by h, shift_instrs ~depth ~by args)
    | If_annotation b ->
        (* A conditional splices its branches in place: no label of its own. *)
        If_annotation
          {
            b with
            then_body = body ~depth b.then_body;
            else_body = Option.map (body ~depth) b.else_body;
          }
    (* The remaining variants carry neither a label nor a nested instruction. *)
    | _ -> i.desc
  in
  { i with desc }

and shift_instrs ~depth ~by l = List.map (shift_instr ~depth ~by) l

(*** The rewrite ***)

(* The block type of the ladder block whose label a handler's catch clause
   targets: it passes the try's parameters through to the [try_table] and
   yields the handler's payload. *)
let handler_blocktype params results : blocktype option =
  if Array.length params = 0 then
    match results with
    | [||] -> None
    | [| t |] -> Some (Valtype t)
    | _ -> Some (Typeuse (None, Some { params = [||]; results }))
  else Some (Typeuse (None, Some { params; results }))

(* The try's parameters, unnamed (a block parameter carries no name). *)
let blocktype_params env (typ : blocktype option) =
  match typ with
  | None | Some (Valtype _) -> [||]
  | Some (Typeuse tu) ->
      Array.map
        (fun p -> { p with Ast.desc = (None, snd p.Ast.desc) })
        (typeuse_functype env tu).params

(* Whether a handler certainly ends by diverging, so that its exit branch
   would be dead code. A conservative syntactic check: a handler it misses only
   gets a dead [br]. *)
let rec diverges_instr (i : _ instr) =
  match i.desc with
  | Folded (h, _) -> diverges_instr h
  | Unreachable | Br _ | Br_table _ | Return | Throw _ | ThrowRef | ReturnCall _
  | ReturnCallRef _ | ReturnCallIndirect _ ->
      true
  | _ -> false

let diverges code =
  match List.rev code with i :: _ -> diverges_instr i | [] -> false

let lower env (i : _ instr) ~label ~typ ~block ~catches ~catch_all =
  let handlers =
    List.map (fun (tag, h) -> (Some tag, h)) catches
    @ Option.fold ~none:[] ~some:(fun h -> [ (None, h) ]) catch_all
  in
  let n = List.length handlers in
  if n = 0 then { i with desc = TryTable { label; typ; catches = []; block } }
  else
    let params = blocktype_params env typ in
    let num k = Ast.no_loc (Num (Uint32.of_int k)) in
    (* A branch to the join from [depth] labels inside it. *)
    let br_join depth =
      no_loc
        (Br
           (match label with
           | Some id -> Ast.no_loc (Id id.Ast.desc)
           | None -> num depth))
    in
    (* Handler [k] (from 0) is reached through the [k]th ladder block, the
       first innermost. *)
    let clauses =
      List.mapi
        (fun k (tag, _) ->
          match tag with Some t -> Catch (t, num k) | None -> CatchAll (num k))
        handlers
    in
    (* The [try_table] is unlabelled, as [Wax_lang.Ast_utils.lower_trycatch] makes it
       (so that the decompiler recovers the structured try): a branch from the
       body to the try's label goes straight to the join, past the [try_table],
       the [n] ladder blocks; every outer label lies past them too. *)
    let block =
      { block with Ast.desc = shift_instrs ~depth:0 ~by:(n + 1) block.desc }
    in
    let try_table =
      no_loc (TryTable { label = None; typ; catches = clauses; block })
    in
    (* Wrap [inner] in the ladder block of handler [k], followed by the handler
       itself: inside the [n - k - 1] outer ladder blocks, where the join (the
       try's label for the handler) is at depth [n - k - 1]. *)
    let rec wrap inner k = function
      | [] -> inner
      | (tag, (h : (_ instr list, _) Ast.annotated)) :: rest ->
          let results =
            match tag with Some t -> tag_payload env t | None -> [||]
          in
          let ladder =
            no_loc
              (Block
                 {
                   label = None;
                   typ = handler_blocktype params results;
                   block = Ast.no_loc inner;
                 })
          in
          let depth = n - k - 1 in
          let code = shift_instrs ~depth:0 ~by:depth h.desc in
          let exit =
            match rest with
            | [] -> []
            | _ when diverges code -> []
            | _ -> [ br_join depth ]
          in
          wrap ((ladder :: code) @ exit) (k + 1) rest
    in
    {
      i with
      desc =
        Block
          {
            label;
            typ;
            block = Ast.no_loc (wrap [ try_table; br_join n ] 0 handlers);
          };
    }

let rec rewrite_instr env (i : _ instr) =
  let body (b : (_ instr list, _) Ast.annotated) =
    { b with desc = rewrite_instrs env b.desc }
  in
  match i.desc with
  | Try { label; typ; block; catches; catch_all } ->
      lower env i ~label ~typ ~block:(body block)
        ~catches:(List.map (fun (tag, h) -> (tag, body h)) catches)
        ~catch_all:(Option.map body catch_all)
  | Block b -> { i with desc = Block { b with block = body b.block } }
  | Loop b -> { i with desc = Loop { b with block = body b.block } }
  | If b ->
      {
        i with
        desc =
          If
            {
              b with
              if_block = body b.if_block;
              else_block = body b.else_block;
            };
      }
  | TryTable b -> { i with desc = TryTable { b with block = body b.block } }
  | Folded (h, args) ->
      { i with desc = Folded (rewrite_instr env h, rewrite_instrs env args) }
  | If_annotation b ->
      {
        i with
        desc =
          If_annotation
            {
              b with
              then_body = body b.then_body;
              else_body = Option.map body b.else_body;
            };
      }
  (* The remaining variants carry no nested instruction. *)
  | _ -> i

and rewrite_instrs env l = List.map (rewrite_instr env) l

let module_ d ((name, fields) : _ module_) =
  let env = module_env d fields in
  let rec field (f : (_ modulefield, _) Ast.annotated) =
    match f.desc with
    | Func fn ->
        { f with desc = Func { fn with instrs = rewrite_instrs env fn.instrs } }
    | Module_if_annotation b ->
        let fields (l : (_ list, _) Ast.annotated) =
          { l with desc = List.map field l.desc }
        in
        {
          f with
          desc =
            Module_if_annotation
              {
                b with
                then_fields = fields b.then_fields;
                else_fields = Option.map fields b.else_fields;
              };
        }
    | _ -> f
  in
  (name, List.map field fields)
