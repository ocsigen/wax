val module_ :
  Utils.Diagnostic.context ->
  ?filename:string ->
  string ->
  Ast.location Ast.Binary.module_
(** [module_ diagnostics ?filename buf] decodes the Wasm binary [buf]. Malformed
    input is reported to [diagnostics] (anchored at the offending byte offset)
    and parsing is aborted via {!Utils.Diagnostic.abort}. *)
