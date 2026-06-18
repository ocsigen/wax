module Diagnostic = Utils.Diagnostic

type value = Bool of bool | Version of int * int * int | String of string

module M = Map.Make (String)

type bindings = value M.t

let of_list l = List.fold_left (fun m (k, v) -> M.add k v m) M.empty l
let is_empty = M.is_empty

(* A version literal is exactly three non-negative integers separated by dots;
   anything else parses as a string. *)
let parse_version v =
  match String.split_on_char '.' v with
  | [ a; b; c ] -> (
      match (int_of_string_opt a, int_of_string_opt b, int_of_string_opt c) with
      | Some a, Some b, Some c when a >= 0 && b >= 0 && c >= 0 -> Some (a, b, c)
      | _ -> None)
  | _ -> None

let parse_define s =
  let name, value =
    match String.index_opt s '=' with
    | Some i ->
        (String.sub s 0 i, Some (String.sub s (i + 1) (String.length s - i - 1)))
    | None -> (s, None)
  in
  if String.equal name "" then Error "empty variable name"
  else
    let v =
      match value with
      | None | Some "true" -> Bool true
      | Some "false" -> Bool false
      | Some v -> (
          match parse_version v with
          | Some (a, b, c) -> Version (a, b, c)
          | None -> String v)
    in
    Ok (name, v)

type result = True | False | Residual of Ast.cond

(* The comparison helpers mirror {!Cond_solver}, kept local so this partial
   evaluator does not depend on the BDD engine. *)
let swap_op : Ast.cmp_op -> Ast.cmp_op = function
  | Le -> Ge
  | Ge -> Le
  | Lt -> Gt
  | Gt -> Lt
  | Eq -> Eq
  | Ne -> Ne

let apply_order (op : Ast.cmp_op) c =
  match op with
  | Eq -> c = 0
  | Ne -> c <> 0
  | Lt -> c < 0
  | Le -> c <= 0
  | Gt -> c > 0
  | Ge -> c >= 0

let is_literal = function
  | Ast.Cond_version _ | Ast.Cond_string _ -> true
  | _ -> false

let bool b = if b then True else False

let report ctx (location : Ast.location) msg =
  Diagnostic.report ctx ~location ~severity:Error
    ~message:(fun f () -> Format.pp_print_string f msg)
    ()

let rec eval ctx env (c : Ast.cond) : result =
  match c with
  | Cond_var v -> (
      match M.find_opt v.desc env with
      | Some (Bool b) -> bool b
      | Some (Version _ | String _) ->
          report ctx v.info
            (Printf.sprintf
               "Variable $%s is set to a non-boolean value but used as a \
                boolean here."
               v.desc);
          Residual c
      | None -> Residual c)
  | Cond_and l -> eval_and ctx env l
  | Cond_or l -> eval_or ctx env l
  | Cond_not e -> (
      match eval ctx env e with
      | True -> False
      | False -> True
      | Residual c -> Residual (Cond_not c))
  | Cond_cmp (op, a, b) -> eval_cmp ctx env c op a b
  | Cond_string _ | Cond_version _ ->
      (* Not a boolean; ill-formed. Left for validation to report. *)
      Residual c

and eval_and ctx env l =
  let rec go acc = function
    | [] -> (
        match List.rev acc with
        | [] -> True
        | [ x ] -> Residual x
        | xs -> Residual (Cond_and xs))
    | c :: rest -> (
        match eval ctx env c with
        | False -> False
        | True -> go acc rest
        | Residual c' -> go (c' :: acc) rest)
  in
  go [] l

and eval_or ctx env l =
  let rec go acc = function
    | [] -> (
        match List.rev acc with
        | [] -> False
        | [ x ] -> Residual x
        | xs -> Residual (Cond_or xs))
    | c :: rest -> (
        match eval ctx env c with
        | True -> True
        | False -> go acc rest
        | Residual c' -> go (c' :: acc) rest)
  in
  go [] l

and eval_cmp ctx env whole op (a : Ast.cond) (b : Ast.cond) =
  match (a, b) with
  | Cond_var v, Cond_version (x, y, z) ->
      cmp_version ctx env whole v op (x, y, z)
  | Cond_version (x, y, z), Cond_var v ->
      cmp_version ctx env whole v (swap_op op) (x, y, z)
  | Cond_var v, Cond_string s -> cmp_string ctx env whole v op s.desc
  | Cond_string s, Cond_var v -> cmp_string ctx env whole v (swap_op op) s.desc
  | Cond_version (x1, y1, z1), Cond_version (x2, y2, z2) ->
      bool (apply_order op (compare (x1, y1, z1) (x2, y2, z2)))
  | Cond_string s1, Cond_string s2 -> (
      match op with
      | Eq -> bool (String.equal s1.desc s2.desc)
      | Ne -> bool (not (String.equal s1.desc s2.desc))
      | _ -> Residual whole)
  | _ -> (
      (* The only other supported form is [=]/[!=] between two boolean
         sub-conditions. *)
      match op with
      | (Eq | Ne) when (not (is_literal a)) && not (is_literal b) ->
          combine_bool op (eval ctx env a) (eval ctx env b)
      | _ -> Residual whole)

and combine_bool op ra rb =
  let neg = function
    | True -> False
    | False -> True
    | Residual c -> Residual (Ast.Cond_not c)
  in
  match (ra, rb) with
  | True, _ -> if op = Ast.Eq then rb else neg rb
  | False, _ -> if op = Ast.Eq then neg rb else rb
  | _, True -> if op = Ast.Eq then ra else neg ra
  | _, False -> if op = Ast.Eq then neg ra else ra
  | Residual ca, Residual cb -> Residual (Cond_cmp (op, ca, cb))

and cmp_version ctx env whole v op ver =
  match M.find_opt v.desc env with
  | Some (Version (a, b, c)) -> bool (apply_order op (compare (a, b, c) ver))
  | Some (Bool _ | String _) ->
      report ctx v.info
        (Printf.sprintf
           "Variable $%s is not set to a version but compared with one here."
           v.desc);
      Residual whole
  | None -> Residual whole

and cmp_string ctx env whole v op s =
  match M.find_opt v.desc env with
  | Some (String s') -> (
      match op with
      | Eq -> bool (String.equal s' s)
      | Ne -> bool (not (String.equal s' s))
      (* Ordering of strings is ill-formed; left for validation to report. *)
      | _ -> Residual whole)
  | Some (Bool _ | Version _) ->
      report ctx v.info
        (Printf.sprintf
           "Variable $%s is not set to a string but compared with one here."
           v.desc);
      Residual whole
  | None -> Residual whole

(* The boundary byte offsets of a conditional and its then-branch. A removed
   branch's source span is recorded so its comments can be dropped (see
   {!Utils.Trivia.drop_in_ranges}) instead of re-attaching to a surviving node.
   The split between the two branches is the end of the then-branch (the point
   just before [@else]), which avoids needing the position of the [@else] token
   itself. *)
let start_of (l : Ast.location) = l.Ast.loc_start.Lexing.pos_cnum
let end_of (l : Ast.location) = l.Ast.loc_end.Lexing.pos_cnum

let branch_end ~default nodes =
  match List.rev nodes with n :: _ -> end_of n.Ast.info | [] -> default

(* Splice out / simplify every conditional in a WAT module, returning the
   specialized module and the byte ranges of the branches that were removed. The
   set of nodes recursed through matches {!Validation.specialize}; the
   difference is that an undetermined conditional is kept (with its condition
   simplified) rather than explored. *)
let module_ ctx env ((name, fields) : Ast.location Ast.Text.module_) :
    Ast.location Ast.Text.module_ * (int * int) list =
  Utils.Debug.timed "specialize" @@ fun () ->
  let open Ast.Text in
  let ranges = ref [] in
  (* The boundary between the two branches. With no else the conditional ends at
     the then-branch, so its own end (past any closing brace) is exact; with an
     else, the best position the AST offers is the end of the last then-node. *)
  let split loc then_nodes ~else_present =
    if else_present then branch_end ~default:(end_of loc) then_nodes
    else end_of loc
  in
  (* Then kept, else dropped: the dropped span runs from the boundary to the end
     of the conditional. *)
  let drop_else loc then_nodes ~else_present =
    ranges := (split loc then_nodes ~else_present, end_of loc) :: !ranges
  in
  (* Else kept (or nothing), then dropped: the dropped span runs from the start
     of the conditional through the boundary. *)
  let drop_then loc then_nodes ~else_present =
    ranges := (start_of loc, split loc then_nodes ~else_present) :: !ranges
  in
  let rec sfields fl = List.concat_map sfield fl
  and sfield (f : (Ast.location modulefield, Ast.location) Ast.annotated) =
    match f.desc with
    | Module_if_annotation { cond; then_fields; else_fields } -> (
        let else_present = Option.is_some else_fields in
        match eval ctx env cond with
        | True ->
            drop_else f.info then_fields ~else_present;
            sfields then_fields
        | False -> (
            drop_then f.info then_fields ~else_present;
            match else_fields with Some e -> sfields e | None -> [])
        | Residual cond ->
            [
              {
                f with
                desc =
                  Module_if_annotation
                    {
                      cond;
                      then_fields = sfields then_fields;
                      else_fields = Option.map sfields else_fields;
                    };
              };
            ])
    | Func r -> [ { f with desc = Func { r with instrs = sinstrs r.instrs } } ]
    | Global r -> [ { f with desc = Global { r with init = sinstrs r.init } } ]
    | Table r ->
        let init =
          match r.init with
          | Init_default -> Init_default
          | Init_expr e -> Init_expr (sinstrs e)
          | Init_segment segs -> Init_segment (List.map sinstrs segs)
        in
        [ { f with desc = Table { r with init } } ]
    | Elem r ->
        [ { f with desc = Elem { r with init = List.map sinstrs r.init } } ]
    | _ -> [ f ]
  and sinstrs l = List.concat_map sinstr l
  and sinstr (i : Ast.location instr) =
    match i.desc with
    | If_annotation { cond; then_body; else_body } -> (
        let else_present = Option.is_some else_body in
        match eval ctx env cond with
        | True ->
            drop_else i.info then_body ~else_present;
            sinstrs then_body
        | False -> (
            drop_then i.info then_body ~else_present;
            match else_body with Some e -> sinstrs e | None -> [])
        | Residual cond ->
            [
              {
                i with
                desc =
                  If_annotation
                    {
                      cond;
                      then_body = sinstrs then_body;
                      else_body = Option.map sinstrs else_body;
                    };
              };
            ])
    | desc -> [ { i with desc = sstructured desc } ]
  and sstructured (desc : Ast.location instr_desc) : Ast.location instr_desc =
    match desc with
    | Block b -> Block { b with block = sinstrs b.block }
    | Loop b -> Loop { b with block = sinstrs b.block }
    | If b ->
        If
          {
            b with
            if_block = { b.if_block with desc = sinstrs b.if_block.desc };
            else_block = { b.else_block with desc = sinstrs b.else_block.desc };
          }
    | TryTable b -> TryTable { b with block = sinstrs b.block }
    | Try b ->
        Try
          {
            b with
            block = sinstrs b.block;
            catches = List.map (fun (idx, l) -> (idx, sinstrs l)) b.catches;
            catch_all = Option.map sinstrs b.catch_all;
          }
    | Folded (h, l) -> Folded ({ h with desc = sstructured h.desc }, sinstrs l)
    | desc -> desc
  in
  let fields = sfields fields in
  ((name, fields), List.rev !ranges)
