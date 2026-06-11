(** Pretty-printing for Wax. *)

val width : int
(** Target line width for Wax output (the Rust Style Guide's default of 100).
    Pass it as [Printer.run]'s [?width] at every Wax module render to a real
    formatter. *)

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
