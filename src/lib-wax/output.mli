(** Pretty-printing for Wax. *)

val instr : Utils.Printer.t -> _ Ast.instr -> unit
val valtype : Utils.Printer.t -> Ast.valtype -> unit
val storagetype : Utils.Printer.t -> Ast.storagetype -> unit

val module_ :
  ?color:Utils.Colors.flag ->
  ?out_channel:out_channel ->
  ?tail:Utils.Trivia.entry list ->
  ?collect:(Ast.location, unit) Hashtbl.t ->
  Utils.Printer.t ->
  trivia:Utils.Trivia.t ->
  Ast.location Ast.module_ ->
  unit
(** [collect], when given, runs as a dry pass that records every looked-up
    location into the table (pass an empty [trivia]); use it to drive
    {!Utils.Trivia.associate}'s [only] argument. *)
