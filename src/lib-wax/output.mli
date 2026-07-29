(** Pretty-printing for Wax. *)

val width : int
(** Target line width for Wax output (the Rust Style Guide's default of 100).
    Applied by {!run_string} / {!run_channel}; exposed for a caller that drives
    a printer some other way. *)

val run_string : (Wax_utils.Printer.t -> unit) -> string
(** [Wax_utils.Printer.run_string] at the Wax {!width}. Render Wax through this
    rather than the printer's own runners, which default to the narrower
    WebAssembly-text width. *)

val run_channel : out_channel -> (Wax_utils.Printer.t -> unit) -> unit
(** [Wax_utils.Printer.run_channel] at the Wax {!width}. *)

val instr : Wax_utils.Printer.t -> _ Ast.instr -> unit
val valtype : Wax_utils.Printer.t -> Ast.valtype -> unit
val comptype : Wax_utils.Printer.t -> Ast.comptype -> unit

val valtype_styled : Wax_utils.Styled_printer.t -> Ast.valtype -> unit
(** Render a type into a caller-supplied styled printer, so it shares a
    diagnostic message's colour theme and width. *)

val comptype_styled : Wax_utils.Styled_printer.t -> Ast.comptype -> unit
val storagetype : Wax_utils.Printer.t -> Ast.storagetype -> unit
val fieldtype : Wax_utils.Printer.t -> Ast.fieldtype -> unit

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
  Wax_utils.Printer.t ->
  trivia:Wax_utils.Trivia.t ->
  Ast.location Ast.module_ ->
  unit
(** Render a module. *)

val collect : Ast.location Ast.module_ -> Wax_utils.Trivia.locations -> unit
(** [collect m set] records every location {!module_} would look up into [set] —
    the dry pass that drives {!Wax_utils.Trivia.associate}'s [only] argument, as
    {!Wax_wasm.Output.collect} does for Wasm text. It needs no printer: the Wax
    printer streams straight from the AST, so the pass is a discarded render
    (there is no laid-out document to walk). *)
