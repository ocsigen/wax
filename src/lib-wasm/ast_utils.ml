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
