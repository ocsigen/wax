val module_ :
  Wax_utils.Diagnostic.context ->
  ?features:Wax_utils.Feature.set ->
  ?filename:string ->
  string ->
  Ast.location Ast.Binary.module_
(** [module_ diagnostics ?filename buf] decodes the Wasm binary [buf]. Malformed
    input is reported to [diagnostics] (anchored at the offending byte offset)
    and parsing is aborted via {!Wax_utils.Diagnostic.abort}. Gated encodings
    (an optional proposal's constructs) are always accepted; each is recorded on
    [features] via {!Wax_utils.Feature.mark_used}, so the caller can learn which
    proposals the module exercises. *)
