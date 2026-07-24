exception Unresolved_reference of Wax_wasm.Ast.location
(** Carries the location of an index or label reference that resolves to nothing
    (it is out of range or names an undeclared entity). Such a module would be
    rejected by validation; conversion gives up rather than inventing a target.
    {!module_} catches this internally and reports it through its diagnostics
    context (then aborts), so it is not raised to callers. *)

val module_ :
  ?strict_constants:bool ->
  ?faithful:bool ->
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_ ->
  Wax_lang.Ast.location Wax_lang.Ast.module_
(** [module_ diagnostics m] converts a WAT module to Wax, reporting to
    [diagnostics] the references it cannot faithfully convert.

    When [strict_constants] is set (default [false]), every numeric constant is
    wrapped in a cast to its concrete type, so Wax type inference cannot re-type
    an otherwise polymorphic literal and a source-level type mismatch survives
    the round-trip.

    When [faithful] is set (default [false], the [--faithful] decompilation
    mode), the stream-reshaping recoveries are turned off so the result
    re-lowers to the exact original opcodes: the [t.eq; i32.eqz] -> [a != b]
    fusion is kept as [!(a == b)], and {!Recover_match}'s flat
    [br_on_cast_fail]-chain arm is disabled (the caller should also re-type
    without the [simplify] pass).

    When [features] is given, a [#![feature = "…"]] inner attribute is stamped
    for each feature recorded as used on it (by the binary decoder or by
    validation) and not already declared by the module, so the output recompiles
    standalone. *)
