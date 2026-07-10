val fold_instr :
  ('a -> 'info Ast.Text.instr -> 'a) -> 'a -> 'info Ast.Text.instr -> 'a
(** [fold_instr f acc i] folds [f] over [i] and every instruction nested within
    it (blocks, [if]/[try] arms, folded operands, branch hints, …), pre-order:
    [i] itself first, then its children. *)

val iter_instr : ('info Ast.Text.instr -> unit) -> 'info Ast.Text.instr -> unit
(** [iter_instr f i] applies [f] to [i] and, recursively, to every instruction
    nested within it. *)

val expand_import_group :
  ('info Ast.Text.modulefield, Ast.location) Ast.annotated ->
  ('info Ast.Text.modulefield, Ast.location) Ast.annotated list
(** Expand a compact [Import_group1]/[Import_group2] field into the individual
    [Import] fields it denotes (each carrying the group's location); any other
    field is returned unchanged as a singleton. *)

val flatten_binary_imports :
  Ast.Binary.import_entry list -> Ast.Binary.import list
(** Flatten binary import-section entries into the individual imports they
    denote (a compact group expands to one import per item). *)
