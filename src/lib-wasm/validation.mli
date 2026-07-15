(** Validation of Wasm Text modules. *)

val validate_refs : bool ref
(** Configuration flag: if true, checks that ref.func uses function indices that
    occur in the module. Default is true. *)

type recorded_type
(** What the type sink records at an instruction's span (see [f]'s
    [?record_types]). Kept unrendered so the editor renders only the few entries
    under the cursor; turn one into its display string with
    {!render_recorded_type}. *)

val render_recorded_type : recorded_type -> string option
(** The display type of a recorded entry: [None] for an instruction that
    produces no value (so hover shows nothing there), otherwise the rendered
    type ([Some "any"] for a value on an unreachable / polymorphic stack). *)

val signature_labels : recorded_type -> (string list * string list) option
(** For a recorded function signature (the identifier of a [call] / [ref.func]),
    its parameter and result types rendered individually, for signature help;
    [None] for any other recorded entry. *)

val type_def_location : recorded_type -> Ast.location option
(** The definition span of the type a recorded entry refers to, for
    go-to-type-definition: a value's named reference type, or the type a type
    identifier names; [None] for entries with no such type. *)

val f :
  ?warn_unused:bool ->
  ?features:Wax_utils.Feature.set ->
  ?record_types:(Ast.location * recorded_type) list ref ->
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.Text.module_ ->
  unit
(** [f modul] validates the given Wasm Text module, including syntactic
    well-formedness checks. Raises exceptions on validation errors.

    When [record_types] is given, every value the validator pushes onto the
    operand stack is appended to it as [(span of the pushing instruction, type)]
    — the type information WAT hover reads. A folded instruction's result is
    attributed to its whole [(op …)] span, and an instruction that produces no
    value records a [No_result] entry (rendering to [None]). Order is
    unspecified and one instruction may contribute several entries (a
    multi-result instruction, one per result). Off (no recording, no cost)
    otherwise.

    When [warn_unused] is set (default [true]), a local declared by a
    [(local …)] but never read is reported as a warning (unless its name starts
    with [_]). Disable it when the module was compiled from Wax, whose own type
    checker already reports unused locals against the Wax source.

    [features] gives the enabled optional features / proposals (default: their
    built-in defaults); a module using a disabled feature is rejected. *)
