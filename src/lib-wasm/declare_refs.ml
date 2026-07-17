open Ast
module T = Text

(* A function reference identified so the same function compares equal whether
   written numerically or by name. Numeric and symbolic forms are not unified: a
   redundant declaration is harmless, a missing one is not, so when in doubt we
   declare. *)
type key = Num of int | Id of string

let key_of_idx (idx : T.idx) : key =
  match idx.desc with
  | T.Num n -> Num (Wax_utils.Uint32.to_int n)
  | T.Id s -> Id s

module KeySet = Set.Make (struct
  type t = key

  let compare = compare
end)

(* The [ref.func] targets occurring in an instruction list, accumulated onto
   [acc]. *)
let refs_instrs acc instrs =
  List.fold_left
    (Ast_utils.fold_instr (fun acc (i : _ T.instr) ->
         match i.desc with T.RefFunc idx -> idx :: acc | _ -> acc))
    acc instrs

let is_conditional (f : (_ T.modulefield, _) annotated) =
  match f.desc with T.Module_if_annotation _ -> true | _ -> false

let funcref : T.reftype = { nullable = false; typ = T.Func }

let module_ ((name, fields) : Ast.location T.module_) : Ast.location T.module_ =
  if List.exists is_conditional fields then (name, fields)
  else begin
    (* [body] = ref.func targets in function bodies (these need declaring);
       [declared] = the functions already "declared as referenceable" — the
       same set the validator builds in [Validation]'s [ctx.refs]: a function
       named by a [ref.func] in a constant initialiser (element / global /
       table), or exported. A function's positional index [fi] is counted like
       the validator does (imports first, then definitions, over the
       group-expanded fields) so an anonymous inline-exported function matches a
       numeric [ref.func]. *)
    let body = ref [] and declared = ref KeySet.empty in
    let note_declared expr =
      List.iter
        (fun idx -> declared := KeySet.add (key_of_idx idx) !declared)
        (refs_instrs [] expr)
    in
    (* A function's own key: its name if it has one, otherwise its position. *)
    let self_key id fi =
      match id with Some (n : T.name) -> Id n.desc | None -> Num fi
    in
    let fi = ref 0 in
    List.iter
      (fun f ->
        match f.desc with
        | T.Import { desc = T.Func _; id; exports; _ } ->
            if exports <> [] then
              declared := KeySet.add (self_key id !fi) !declared;
            incr fi
        | T.Import _ -> ()
        | T.Func { instrs; id; exports; _ } ->
            body := refs_instrs !body instrs;
            if exports <> [] then
              declared := KeySet.add (self_key id !fi) !declared;
            incr fi
        | T.Global { init; _ } -> note_declared init
        | T.Elem { init; mode; _ } -> (
            List.iter note_declared init;
            match mode with Active (_, off) -> note_declared off | _ -> ())
        | T.Table { init; _ } -> (
            match init with
            | Init_default -> ()
            | Init_expr e -> note_declared e
            | Init_segment segs -> List.iter note_declared segs)
        | T.Export { kind = Func; index; _ } ->
            declared := KeySet.add (key_of_idx index) !declared
        | _ -> ())
      (List.concat_map Ast_utils.expand_import_group fields);
    (* The undeclared body references, in source order, without duplicates. *)
    let undeclared =
      List.rev
        (fst
           (List.fold_left
              (fun (acc, seen) idx ->
                let k = key_of_idx idx in
                if KeySet.mem k !declared || KeySet.mem k seen then (acc, seen)
                else (idx :: acc, KeySet.add k seen))
              ([], KeySet.empty) (List.rev !body)))
    in
    if undeclared = [] then (name, fields)
    else
      let new_inits =
        List.map (fun idx -> [ Ast.no_loc (T.RefFunc idx) ]) undeclared
      in
      (* Extend the first declarative funcref segment if there is one, else
         append a fresh one. *)
      let extended = ref false in
      let fields =
        List.map
          (fun f ->
            match f.desc with
            | T.Elem ({ mode = Declare; typ = { typ = Func; _ }; init; _ } as e)
              when not !extended ->
                extended := true;
                { f with desc = T.Elem { e with init = init @ new_inits } }
            | _ -> f)
          fields
      in
      let fields =
        if !extended then fields
        else
          fields
          @ [
              Ast.no_loc
                (T.Elem
                   {
                     id = None;
                     typ = funcref;
                     init = new_inits;
                     mode = Declare;
                   });
            ]
      in
      (name, fields)
  end
