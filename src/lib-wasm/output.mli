(** Pretty-printing for Wasm Text Format. *)

val escape_string : string -> int * string
(** [escape_string s] returns a pair [(len, escaped)] where [escaped] is the
    escaped version of [s] suitable for WAT string literals, and [len] is its
    display length. *)

val module_ :
  ?color:Utils.Colors.flag ->
  ?out_channel:out_channel ->
  ?tail:Utils.Trivia.entry list ->
  ?collect:(Ast.location, unit) Hashtbl.t ->
  Utils.Printer.t ->
  trivia:Utils.Trivia.t ->
  Ast.location Ast.Text.module_ ->
  unit
(** [collect], when given, runs as a dry pass that records every looked-up
    location into the table (pass an empty [trivia]); use it to drive
    {!Utils.Trivia.associate}'s [only] argument. *)

val instr : Utils.Printer.t -> Ast.location Ast.Text.instr -> unit
