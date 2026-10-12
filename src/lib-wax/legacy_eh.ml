open Ast

(* The labels a function defines (its body's label included). A fresh label
   distinct from all of them can neither shadow an enclosing label nor be
   shadowed by a nested one. *)
let defined_labels (label, instrs) =
  let acc = ref (Option.to_list label) in
  let add = function Some l -> acc := l :: !acc | None -> () in
  List.iter
    (Ast_utils.iter_instr (fun i ->
         match i.desc with
         | Block { label; _ }
         | Loop { label; _ }
         | While { label; _ }
         | If { label; _ }
         | TryTable { label; _ }
         | Try { label; _ }
         | TryCatch { label; _ } ->
             add label
         | Dispatch { arms; _ } -> List.iter (fun (l, _) -> add (Some l)) arms
         | _ -> ()))
    instrs;
  List.map (fun (l : label) -> l.desc) !acc

let fresh used =
  let rec pick i =
    let name = if i = 0 then "join" else "join" ^ string_of_int i in
    if List.mem name !used then pick (i + 1) else name
  in
  let name = pick 0 in
  used := name :: !used;
  name

(* Whether a handler body certainly ends by diverging, so that nothing follows
   it. A conservative syntactic check: an arm it misses only gets a dead
   [br]. *)
let diverges (body : (_ instr list, _) annotated) =
  match List.rev body.desc with
  | { desc = Unreachable | Br _ | Br_table _ | Return _ | TailCall _; _ } :: _
  | { desc = Throw _ | ThrowRef _; _ } :: _ ->
      true
  | _ -> false

let lower ~used ~arity (i : location instr) ~label ~typ ~block ~catches
    ~catch_all =
  let handlers =
    List.map (fun (tag, h) -> (Some tag, h)) catches
    @ Option.fold ~none:[] ~some:(fun h -> [ (None, h) ]) catch_all
  in
  (* Every handler but the last exits the construct explicitly. *)
  let rec exits = function
    | [] | [ _ ] -> []
    | (_, h) :: rest -> not (diverges h) :: exits rest
  in
  let exits = exits handlers in
  let label =
    match label with
    | Some _ -> label
    | None when List.mem true exits -> Some (no_loc (fresh used))
    | None -> None
  in
  let br () =
    let hole () = no_loc_instr Hole in
    let value =
      match arity with
      | 0 -> None
      | 1 -> Some (hole ())
      | n -> Some (no_loc_instr (Sequence (List.init n (fun _ -> hole ()))))
    in
    no_loc_instr (Br (Option.get label, value))
  in
  (* A trailing statement of bare holes ([_;], [(_, _);]) only leaves the values
     on the stack, which the [br]'s own holes then take: it goes. *)
  let is_hole (i : _ instr) = match i.desc with Hole -> true | _ -> false in
  let with_exit l =
    match List.rev l with
    | { desc = Hole; _ } :: rest when arity = 1 -> List.rev (br () :: rest)
    | { desc = Sequence s; _ } :: rest
      when arity > 1 && List.length s = arity && List.for_all is_hole s ->
        List.rev (br () :: rest)
    | _ -> l @ [ br () ]
  in
  let arms =
    List.mapi
      (fun k (tag, (h : (_ instr list, _) annotated)) ->
        let arm_body =
          if List.nth_opt exits k = Some true then
            { h with desc = with_exit h.desc }
          else h
        in
        { arm_tag = tag; arm_ref = false; arm_types = [||]; arm_body })
      handlers
  in
  { i with desc = TryCatch { label; typ; block; arms } }

(* Bottom-up, so a nested legacy try is rewritten before the one around it. *)
let rec instr d ~arities ~used (i : location instr) =
  let desc =
    Ast_utils.map_desc ~instr:(instr d ~arities ~used)
      ~block:(Ast_utils.smart_map (instr d ~arities ~used))
      i.desc
  in
  let i = if desc == i.desc then i else { i with desc } in
  match i.desc with
  | Try { typ; _ } when Array.length typ.params > 0 ->
      (* The structured try takes no parameters (nor could its handler ladder
         pass them through). *)
      Wax_utils.Diagnostic.report d ~location:i.info ~severity:Error
        ~message:
          (Wax_utils.Message.text
             "This legacy try takes parameters, which a structured try cannot \
              take.")
        ~hint:
          (Wax_utils.Message.text
             "Pass the values to its body through locals instead.")
        ();
      i
  | Try { label; typ; block; catches; catch_all } ->
      let arity =
        match Hashtbl.find_opt arities i.info with
        | Some n -> n
        | None -> Array.length typ.results
      in
      lower ~used ~arity i ~label ~typ ~block ~catches ~catch_all
  | _ -> i

let rec field d ~arities (f : (_ modulefield, _) annotated) =
  match f.desc with
  | Func ({ body = (label, instrs) as body; _ } as fn) ->
      let used = ref (defined_labels body) in
      {
        f with
        desc =
          Func
            { fn with body = (label, List.map (instr d ~arities ~used) instrs) };
      }
  | Conditional b ->
      let fields (l : (_ list, _) annotated) =
        { l with desc = List.map (field d ~arities) l.desc }
      in
      {
        f with
        desc =
          Conditional
            {
              b with
              then_fields = fields b.then_fields;
              else_fields = Option.map fields b.else_fields;
            };
      }
  (* A legacy try in an initializer is invalid (not constant) anyway. *)
  | _ -> f

let module_ d ~typed m =
  (* An unannotated try takes its result type from its context: the typer
     records the number of values each one yields. *)
  let arities = Hashtbl.create 16 in
  Ast_utils.iter_module_instr
    (fun (i : _ instr) ->
      match i.desc with
      | Try _ ->
          Hashtbl.replace arities (snd i.info) (Array.length (fst i.info))
      | _ -> ())
    typed;
  List.map (field d ~arities) m
