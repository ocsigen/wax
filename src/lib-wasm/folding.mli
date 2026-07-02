(** Folded/Unfolded instruction conversion. *)

val fold :
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.Text.module_ ->
  Ast.location Ast.Text.module_
(** [fold d modul] converts unfolded instructions (like [i32.add]) into folded
    S-expressions (like [(i32.add ...)]) where possible in the module. Folding
    is arity-driven and resolves names per conditional branch, so it needs the
    located AST (to model branch conditions). Because it runs on input that is
    not validated first (an unvalidated wat->wat conversion or a trusted
    wasm->wat binary), an unbound index — or one that resolves to the wrong kind
    of definition — is reported to [d] rather than raising. *)

val unfold : 'info Ast.Text.module_ -> 'info Ast.Text.module_
(** [unfold modul] flattens folded S-expressions into linear instruction
    sequences in the module. *)
