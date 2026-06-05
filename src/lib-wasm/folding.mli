(** Folded/Unfolded instruction conversion. *)

val fold : Ast.location Ast.Text.module_ -> Ast.location Ast.Text.module_
(** [fold modul] converts unfolded instructions (like [i32.add]) into folded
    S-expressions (like [(i32.add ...)]) where possible in the module. Folding
    is arity-driven and resolves names per conditional branch, so it needs the
    located AST (to model branch conditions). *)

val unfold : 'info Ast.Text.module_ -> 'info Ast.Text.module_
(** [unfold modul] flattens folded S-expressions into linear instruction
    sequences in the module. *)
