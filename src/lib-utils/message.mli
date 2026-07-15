(** A structured diagnostic message: prose that reflows at the target width,
    plus styled/quoted atoms and escape-hatch fragments that render an AST
    fragment (a type, an instruction) through the shared pretty-printer.

    A message is a data value, rendered late: the theme (colour) and width are
    supplied only when it is emitted, so the same message renders to a themed
    terminal (colour, wrapped), or is flattened to a plain single-line string
    for the JSON / short output formats.

    An emphasized atom ({!ident}, {!code}, and the [typ] combinators built on
    {!raw}) is shown
    {e in its colour when the theme is coloured, and wrapped in ['…'] when it is
       not}: JSON/short (always uncoloured) are therefore always quoted, while
    an interactive terminal is coloured and unquoted. Plain prose ({!text}) is
    never quoted or styled; constants are styled but never quoted. *)

type t

val text : string -> t
(** Prose. Splits on spaces into words joined by soft breaks, so it reflows at
    the render width; an embedded newline is a hard break. Runs of spaces
    (including leading/trailing ones) become a single soft break, so fragments
    joined with {!(^^)} can carry their own separating space. *)

val ident : string -> t
(** An emphasized source identifier: coloured [Identifier] when the theme is
    coloured, else quoted ['…']. *)

val code : string -> t
(** An emphasized inline code token (an instruction, an operator, a literal
    snippet): coloured [Keyword] when the theme is coloured, else quoted. *)

val styled : Colors.style -> string -> t
(** One unbreakable styled atom, never quoted. *)

val int : int -> t
val int64 : Int64.t -> t
val bool : bool -> t

val raw : (Styled_printer.t -> unit) -> t
(** The escape hatch: run an imperative callback against the render-time styled
    printer (already carrying the diagnostic's theme and width). The [typ]
    combinators of the Wax typer and the Wasm validator are built on this, so
    they can plug the [Output] type printers in without lib-utils depending on
    them. *)

val empty : t
val concat : t list -> t

val ( ^^ ) : t -> t -> t
(** Juxtapose with no space between. *)

val ( ++ ) : t -> t -> t
(** Juxtapose with a soft (wrap-point) space between. *)

val group : t -> t
(** Lay the argument out as a keep-together box (indented when broken); used to
    wrap a rendered type so it does not reflow word-by-word. *)

val enumerate : ?conj:string -> t list -> t
(** ["a, b or c"] — join with commas and [conj] (default ["or"]) before the last
    item. Used for did-you-mean lists. *)

val render_into :
  theme:Colors.theme -> width:int -> Format.formatter -> t -> unit
(** Emit [t] onto [fmt], laid out through the shared pretty-printer at [width]
    using [theme]. *)

val to_plain_string : t -> string
(** Render at effectively-infinite width with {!Colors.no_color}, returning a
    flat, ANSI-free string. Used for the JSON and short output formats. *)
