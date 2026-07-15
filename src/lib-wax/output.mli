(** Pretty-printing for Wax. *)

val width : int
(** Target line width for Wax output (the Rust Style Guide's default of 100).
    Pass it as [Printer.run]'s [?width] at every Wax module render to a real
    formatter. *)

val instr : Wax_utils.Printer.t -> _ Ast.instr -> unit
val valtype : Wax_utils.Printer.t -> Ast.valtype -> unit
val comptype : Wax_utils.Printer.t -> Ast.comptype -> unit
val storagetype : Wax_utils.Printer.t -> Ast.storagetype -> unit

val subtype :
  Wax_utils.Printer.t ->
  (Ast.ident * Ast.subtype, Ast.location) Ast.annotated ->
  unit
(** Print a named type definition, [type name = …;]. Small definitions stay on
    one line. *)

val module_ :
  ?color:Wax_utils.Colors.flag ->
  ?out_channel:out_channel ->
  ?tail:Wax_utils.Trivia.entry list ->
  ?collect:(Ast.location, unit) Hashtbl.t ->
  Wax_utils.Printer.t ->
  trivia:Wax_utils.Trivia.t ->
  Ast.location Ast.module_ ->
  unit
(** [collect], when given, runs as a dry pass that records every looked-up
    location into the table (pass an empty [trivia]); use it to drive
    {!Wax_utils.Trivia.associate}'s [only] argument. *)
