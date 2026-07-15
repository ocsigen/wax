(** Type checking and validation for Wax modules. *)

type typed_module_annotation = Ast.storagetype option array * Ast.location

type inferred_module_annotation =
  Infer.inferred_type Infer.Cell.t array * Ast.location
(** The typed-tree annotation before the inference cells are resolved to
    {!typed_module_annotation}: each node carries the inference cells for the
    values it leaves on the stack, plus its span. Unlike the resolved form it
    keeps the distinctions {!Infer.output_inferred_type} renders — flexible
    numeric literals ([number]/[int]/…), unknown/unreachable types ([any]), and
    inline anonymous composite types — which resolution collapses. Produced by
    {!f_infer}. *)

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

type hover_target =
  | Value_type of Infer.inferred_valtype
  | Type_def of Ast.subtype
      (** What a resolved reference summarises for a hover on a name that is not
          itself an expression: a variable's type, or a referenced type's
          definition. Kept as data so the consumer renders only the one it needs
          (a check formats nothing). *)

type reference = {
  use : Ast.location;
  definitions : Ast.location list;
  hover : hover_target option;
}
(** A resolved name or label reference: the source span of a *use*, the span(s)
    of the *definition(s)* it binds to — several only under conditional
    compilation — and, for a name that is not itself an expression (a type
    reference, an assignment target, a bare global), what it resolves to for a
    hover. Collected by {!f_infer} for go-to-definition and hover. *)

val f_infer :
  ?simplify:bool ->
  ?warn_unused:bool ->
  ?resolve_links:reference list ref option ->
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.module_ ->
  types * inferred_module_annotation Ast.module_
(** As {!f}, but returns the typed tree with its inference cells intact rather
    than resolved to storage types — {!f} is exactly [f_infer] followed by that
    resolution, and both emit the same diagnostics. Lets a consumer render types
    the way diagnostics do (via {!Infer.output_inferred_type}); used by the
    editor for hover.

    When [resolve_links] is a [Some ref], every name and label reference
    resolved while type checking is appended to it as a {!reference} (use span
    -> definition spans), for go-to-definition. Left [None] (the default) an
    ordinary run records nothing. *)

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
