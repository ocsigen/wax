(** Validation of Wasm Text modules. *)

val validate_refs : bool ref
(** Configuration flag: if true, checks that ref.func uses function indices that
    occur in the module. Default is true. *)

val f : Utils.Diagnostic.context -> Ast.location Ast.Text.module_ -> unit
(** [f modul] validates the given Wasm Text module, including syntactic
    well-formedness checks. Raises exceptions on validation errors. *)
