exception Unresolved_reference
(** Raised by {!module_} when an index or label reference resolves to nothing
    (it is out of range or names an undeclared entity). Such a module would be
    rejected by validation; conversion gives up rather than inventing a target.
*)

val module_ :
  ?strict_constants:bool ->
  Wax_utils.Diagnostic.context ->
  Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_ ->
  Wax_lang.Ast.location Wax_lang.Ast.module_
(** [module_ diagnostics m] converts a WAT module to Wax, reporting to
    [diagnostics] the references it cannot faithfully convert.

    When [strict_constants] is set (default [false]), every numeric constant is
    wrapped in a cast to its concrete type, so Wax type inference cannot re-type
    an otherwise polymorphic literal and a source-level type mismatch survives
    the round-trip. *)
