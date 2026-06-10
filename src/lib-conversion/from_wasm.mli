val module_ :
  ?strict_constants:bool ->
  Utils.Diagnostic.context ->
  Wasm.Ast.location Wasm.Ast.Text.module_ ->
  Wax.Ast.location Wax.Ast.module_
(** [module_ diagnostics m] converts a WAT module to Wax, reporting to
    [diagnostics] the references it cannot faithfully convert.

    When [strict_constants] is set (default [false]), every numeric constant is
    wrapped in a cast to its concrete type, so Wax type inference cannot re-type
    an otherwise polymorphic literal and a source-level type mismatch survives
    the round-trip. *)
