(** Type checking and validation for Wax modules. *)

type typed_module_annotation = Ast.storagetype option array * Ast.location
type types

val f :
  ?simplify:bool ->
  ?warn_unused:bool ->
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.module_ ->
  types * typed_module_annotation Ast.module_
(** [f fields] performs type checking on the given list of Wax module fields. It
    verifies types, signatures, and other semantic rules.

    When [simplify] is set (default [false]), the typed AST is also rewritten:
    casts the inferred types make redundant are dropped, and [&?extern]/[&?any]
    casts of non-nullable arguments are tightened to [&extern]/[&any]. This is
    intended for the Wasm-to-Wax conversion, where casts are inserted to pin
    types; hand-written Wax is left untouched.

    When [warn_unused] is set (default [false]), a [let]-bound local that is
    never read is reported as a warning (unless its name starts with [_]). Only
    honored for conditional-free modules. *)

val check :
  ?warn_unused:bool ->
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.module_ ->
  unit
(** [check] type-checks the module for errors like [f], but does not build the
    typed module. Use it on the validation-only paths (a same-format wax -> wax
    conversion, the [check] command) that discard the typed AST; [f] is reserved
    for conversion to Wasm/WAT, which consumes it.

    [warn_unused] behaves as for [f]. *)

val erase_types :
  typed_module_annotation Ast.module_ -> Ast.location Ast.module_
(** [erase_types modul] removes type annotations from the module, returning it
    to its original location-only annotation state. *)

val get_type_definition :
  Wax_utils.Diagnostic.context ->
  types ->
  (string, Ast.location) Ast.annotated ->
  Ast.subtype option
(** [get_type_definition context types id] returns the subtype definition for
    the given identifier, if it exists. *)
