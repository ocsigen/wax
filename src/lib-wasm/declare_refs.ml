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

(* The [ref.func] targets occurring in an instruction list, innermost-first
   accumulated onto [acc]. *)
let rec refs_instr acc (i : _ T.instr) =
  match i.desc with
  | T.RefFunc idx -> idx :: acc
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      refs_instrs acc block
  | If { if_block; else_block; _ } ->
      refs_instrs (refs_instrs acc if_block.desc) else_block.desc
  | Try { block; catches; catch_all; _ } -> (
      let acc = refs_instrs acc block in
      let acc =
        List.fold_left (fun acc (_, is) -> refs_instrs acc is) acc catches
      in
      match catch_all with Some is -> refs_instrs acc is | None -> acc)
  | Folded (i, is) -> refs_instrs (refs_instr acc i) is
  | _ -> acc

and refs_instrs acc instrs = List.fold_left refs_instr acc instrs

let is_conditional (f : (_ T.modulefield, _) annotated) =
  match f.desc with T.Module_if_annotation _ -> true | _ -> false

let funcref : T.reftype = { nullable = false; typ = T.Func }

let module_ ((name, fields) : Ast.location T.module_) : Ast.location T.module_ =
  if List.exists is_conditional fields then (name, fields)
  else begin
    (* [body] = ref.func targets in function bodies (these need declaring);
       [declared] = those already referenced in element / global initialisers. *)
    let body = ref [] and declared = ref KeySet.empty in
    let note_declared expr =
      List.iter
        (fun idx -> declared := KeySet.add (key_of_idx idx) !declared)
        (refs_instrs [] expr)
    in
    List.iter
      (fun f ->
        match f.desc with
        | T.Func { instrs; _ } -> body := refs_instrs !body instrs
        | T.Global { init; _ } -> note_declared init
        | T.Elem { init; mode; _ } -> (
            List.iter note_declared init;
            match mode with Active (_, off) -> note_declared off | _ -> ())
        | _ -> ())
      fields;
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
