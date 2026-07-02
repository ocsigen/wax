(** Validation of Wasm Text modules. *)

val validate_refs : bool ref
(** Configuration flag: if true, checks that ref.func uses function indices that
    occur in the module. Default is true. *)

val f :
  ?warn_unused:bool ->
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.Text.module_ ->
  unit
(** [f modul] validates the given Wasm Text module, including syntactic
    well-formedness checks. Raises exceptions on validation errors.

    When [warn_unused] is set (default [true]), a local declared by a
    [(local …)] but never read is reported as a warning (unless its name starts
    with [_]). Disable it when the module was compiled from Wax, whose own type
    checker already reports unused locals against the Wax source.

    [features] gives the enabled optional features / proposals (default: their
    built-in defaults); a module using a disabled feature is rejected. *)
