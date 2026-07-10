open Ast
open Ast.Text

(* The canonical pre-order walk of an instruction tree: visit [i], then recurse
   into every nested instruction it carries. Keeping this in one place means a
   new instruction that nests others (or a missed case, as [Hinted] once was)
   is handled for every traversal at once. *)
let rec fold_instr f acc (i : 'info instr) =
  let acc = f acc i in
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      fold_instrs f acc block.desc
  | If { if_block; else_block; _ } ->
      fold_instrs f (fold_instrs f acc if_block.desc) else_block.desc
  | Try { block; catches; catch_all; _ } ->
      let acc = fold_instrs f acc block.desc in
      let acc =
        List.fold_left
          (fun acc (_, is) -> fold_instrs f acc is.desc)
          acc catches
      in
      Option.fold ~none:acc ~some:(fun b -> fold_instrs f acc b.desc) catch_all
  | Folded (h, is) -> fold_instrs f (fold_instr f acc h) is
  | Hinted (_, inner) -> fold_instr f acc inner
  (* The remaining variants carry no nested instruction. *)
  | _ -> acc

and fold_instrs f acc l = List.fold_left (fold_instr f) acc l

let iter_instr f i = fold_instr (fun () i -> f i) () i

(* compact-import-section: expand an [Import_group1]/[Import_group2] field into
   the individual [Import] fields it stands for (carrying the group's location);
   any other field is returned unchanged as a singleton. Passes that only need to
   see individual imports flatten a field list with
   [List.concat_map expand_import_group]. *)
let expand_import_group f =
  match f.desc with
  | Import_group1 { module_; items } ->
      List.map
        (fun (name, id, desc) ->
          { f with desc = Import { module_; name; id; desc; exports = [] } })
        items
  | Import_group2 { module_; desc; items } ->
      List.map
        (fun (name, id) ->
          { f with desc = Import { module_; name; id; desc; exports = [] } })
        items
  | _ -> [ f ]

(* Flatten binary import-section entries back into the individual imports they
   denote, for the passes that only need the flat import list (index counting). *)
let flatten_binary_imports (entries : Ast.Binary.import_entry list) :
    Ast.Binary.import list =
  List.concat_map
    (function
      | Ast.Binary.Single i -> [ i ]
      | Group1 { module_; items } ->
          List.map
            (fun (name, desc) -> { Ast.Binary.module_; name; desc })
            items
      | Group2 { module_; desc; names } ->
          List.map (fun name -> { Ast.Binary.module_; name; desc }) names)
    entries
