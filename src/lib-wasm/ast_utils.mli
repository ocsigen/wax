val fold_instr :
  ('a -> 'info Ast.Text.instr -> 'a) -> 'a -> 'info Ast.Text.instr -> 'a
(** [fold_instr f acc i] folds [f] over [i] and every instruction nested within
    it (blocks, [if]/[try] arms, folded operands, branch hints, …), pre-order:
    [i] itself first, then its children. *)

val iter_instr : ('info Ast.Text.instr -> unit) -> 'info Ast.Text.instr -> unit
(** [iter_instr f i] applies [f] to [i] and, recursively, to every instruction
    nested within it. *)
