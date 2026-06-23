(** Pretty-printing for Wasm Text Format. *)

val escape_string : string -> int * string
(** [escape_string s] returns a pair [(len, escaped)] where [escaped] is the
    escaped version of [s] suitable for WAT string literals, and [len] is its
    display length. *)

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
