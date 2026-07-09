(** Pretty-printing for Wasm Text Format. *)

val id_string : string -> string
(** [id_string x] is the source text of the identifier whose name (without the
    leading [$]) is [x]: [$x] for a plain identifier, or the quoted [$"…"] form
    with escaping otherwise. This is how {!module_} renders identifiers. *)

val module_ :
  ?color:Wax_utils.Colors.flag ->
  ?out_channel:out_channel ->
  ?tail:Wax_utils.Trivia.entry list ->
  ?collect:(Ast.location, unit) Hashtbl.t ->
  Wax_utils.Printer.t ->
  trivia:Wax_utils.Trivia.t ->
  Ast.location Ast.Text.module_ ->
  unit
(** [collect], when given, runs as a dry pass that records every looked-up
    location into the table (pass an empty [trivia]); use it to drive
    {!Wax_utils.Trivia.associate}'s [only] argument. *)

val instr : Wax_utils.Printer.t -> Ast.location Ast.Text.instr -> unit
