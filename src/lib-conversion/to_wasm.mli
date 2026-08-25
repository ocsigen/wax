val module_ :
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Wax_lang.Typing.types ->
  Wax_lang.Typing.typed_module_annotation Wax_lang.Ast.module_ ->
  Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
(** [?features] carries the resolved (declared ∪ enabled) feature set. When
    compact-import-section is enabled, an [import "m" { … }] block lowers to a
    compact per-item [Import_group1] (the shared-type [Import_group2] text form
    is name-only, and every wax item binds a name; the binary encoder still
    picks the shared-type encoding when the types agree); a singleton block
    flattens to a plain import. Without the feature every block flattens to
    individual imports. *)
