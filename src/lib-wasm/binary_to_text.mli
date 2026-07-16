val module_ :
  ?features:Wax_utils.Feature.set ->
  'info Ast.Binary.module_ ->
  'info Ast.Text.module_
(** When [features] is given, a [(@feature "…")] annotation is emitted for each
    feature recorded as used on it (by {!Wasm_parser.module_}), so the text
    output declares the optional proposals the binary exercises. *)
