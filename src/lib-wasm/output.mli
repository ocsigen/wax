(** Pretty-printing for Wasm Text Format. *)

val id_string : string -> string
(** [id_string x] is the source text of the identifier whose name (without the
    leading [$]) is [x]: [$x] for a plain identifier, or the quoted [$"…"] form
    with escaping otherwise. This is how {!module_} renders identifiers. *)

type document
(** A module laid out into the printer's intermediate tree. Building it for a
    large module allocates heavily, so a caller that needs both the dry
    trivia-collection pass and the real emit should {!prepare} it once and drive
    both off the result. *)

val prepare : Ast.location Ast.Text.module_ -> document
(** Lay a module out into its intermediate {!document}. Pure; no printing. *)

val collect : document -> Wax_utils.Trivia.locations -> unit
(** [collect doc set] records every location [emit doc] would look up into [set]
    — the dry pass that drives {!Wax_utils.Trivia.associate}'s [only] argument,
    without laying anything out. *)

val emit :
  ?color:Wax_utils.Colors.flag ->
  ?out_channel:out_channel ->
  ?tail:Wax_utils.Trivia.entry list ->
  Wax_utils.Printer.t ->
  trivia:Wax_utils.Trivia.t ->
  document ->
  unit
(** Render a prepared {!document}. *)

val module_ :
  ?color:Wax_utils.Colors.flag ->
  ?out_channel:out_channel ->
  ?tail:Wax_utils.Trivia.entry list ->
  ?collect:Wax_utils.Trivia.locations ->
  Wax_utils.Printer.t ->
  trivia:Wax_utils.Trivia.t ->
  Ast.location Ast.Text.module_ ->
  unit
(** {!prepare} then {!collect} (when [collect] is given, a dry pass — pass an
    empty [trivia]) or {!emit}, in one call. Convenience for a single-pass
    caller; a two-pass caller should {!prepare} once and share the result. *)

val instr : Wax_utils.Printer.t -> Ast.location Ast.Text.instr -> unit

val subtype_string :
  (Ast.Text.name option * Ast.Text.subtype, Ast.location) Ast.annotated ->
  string
(** A type definition ([(type $id …)]) rendered to a plain uncoloured string,
    for showing on hover over a type identifier. *)
