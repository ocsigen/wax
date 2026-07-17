val module_ :
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Wax_lang.Typing.types ->
  Wax_lang.Typing.typed_module_annotation Wax_lang.Ast.module_ ->
  Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
(** [?features] carries the resolved (declared ∪ enabled) feature set. When
    compact-import-section is enabled, an [import "m" { … }] block lowers to a
    compact group ([Import_group2] when all items share one import type, else
    [Import_group1]); a singleton block flattens to a plain import. Without the
    feature every block flattens to individual imports. *)
