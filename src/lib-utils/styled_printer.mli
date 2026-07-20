(** A pretty-printing context pairing a layout {!Printer.t} with a colour
    {!Colors.theme} and the {!Trivia} (comments, blank lines) to weave back into
    the output. The styling and trivia plumbing is shared by the Wax and the
    WebAssembly printers, which wrap this context with their own format-specific
    state. *)

type t = {
  printer : Printer.t;
  theme : Colors.theme;
  mutable style_override : Colors.style option;
      (** When set, every styled atom is rendered in this style instead of its
          own; used to colour an expression printed inside an attribute. Left
          [None] by printers that do not need it. *)
  trivia : Trivia.t;
  seen : Trivia.locations;
  collect : Trivia.locations option;
}

val create :
  printer:Printer.t ->
  theme:Colors.theme ->
  ?collect:Trivia.locations ->
  trivia:Trivia.t ->
  unit ->
  t
(** Build a context with a fresh [seen] table and no {!style_override}. *)

val print_styled : t -> Colors.style -> ?len:int option -> string -> unit
(** Emit [text] wrapped in the theme's escape sequence for the given style — or
    for the {!style_override}, when one is in effect. [len] overrides the text's
    display width. *)

val comment : t -> string -> unit
(** Emit comment text in the comment style. *)

val print_trivia : t -> Trivia.entry list -> unit
(** Emit a list of trivia entries (comments and blank lines). *)

val get_trivia : t -> Ast.location option -> Trivia.associated
(** Look up (and mark as seen) the trivia associated with a location. *)

val atomic_node : t -> Ast.location option -> (unit -> unit) -> unit
(** Emit a node's [before] trivia, run the body, then its [within]/[after]
    trivia. *)

val with_style : t -> Colors.style -> (unit -> unit) -> unit
(** Run the body with {!style_override} set to the given style; a no-op on the
    override if one is already in effect. *)
