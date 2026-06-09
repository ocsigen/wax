(** Pretty-printing for Wax. *)

val instr : Utils.Printer.t -> _ Ast.instr -> unit
val valtype : Utils.Printer.t -> Ast.valtype -> unit
val storagetype : Utils.Printer.t -> Ast.storagetype -> unit

val module_ :
  ?color:Utils.Colors.flag ->
  ?out_channel:out_channel ->
  ?tail:Utils.Trivia.entry list ->
  Utils.Printer.t ->
  trivia:Utils.Trivia.t ->
  Ast.location Ast.module_ ->
  unit
