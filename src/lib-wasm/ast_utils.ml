open Ast
open Ast.Text

let rec iter_instr f instr =
  f instr.info;
  (* Apply f to the current instruction's info *)
  match instr.desc with
  | Block { block; _ } | Loop { block; _ } -> List.iter (iter_instr f) block
  | If { if_block; else_block; _ } ->
      List.iter (iter_instr f) if_block.desc;
      List.iter (iter_instr f) else_block.desc
  | TryTable { block; _ } -> List.iter (iter_instr f) block
  | Try { block; catches; catch_all; _ } ->
      List.iter (iter_instr f) block;
      List.iter (fun (_, instrs) -> List.iter (iter_instr f) instrs) catches;
      Option.iter (List.iter (iter_instr f)) catch_all
  | Folded (i, instrs) ->
      iter_instr f i;
      List.iter (iter_instr f) instrs
  (* All other variants don't contain nested 'info instr, so they do nothing *)
  | _ -> ()
