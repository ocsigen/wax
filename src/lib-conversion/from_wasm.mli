val module_ :
  Utils.Diagnostic.context ->
  Wasm.Ast.location Wasm.Ast.Text.module_ ->
  Wax.Ast.location Wax.Ast.module_
(** [module_ diagnostics m] converts a WAT module to Wax, reporting to
    [diagnostics] the references it cannot faithfully convert. *)
