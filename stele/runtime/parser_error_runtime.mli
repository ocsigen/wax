(** Runtime resolution of the [<N>] delimiter markers stele's generated messages
    carry.

    A stele-generated message may embed a marker line
    [<N>This '(' opens the enclosing construct.], where [N] is a 1-based index
    into the parser's stack suffix at the error. Resolving it needs the running
    parser's environment, so the generator (a build-time tool) cannot do it —
    the adopter's error handler must, at the point it holds the incremental
    engine's [env]. This library is that resolution, extracted once so every
    adopter shares the subtle half (the
    walk-back-over-blanks-to-the-opening-delimiter refinement in particular)
    rather than reimplementing it.

    It depends on [menhirLib] and the standard library only, so it compiles
    under [wasm_of_ocaml] / [js_of_ocaml] as well as native. *)

module type ENGINE = sig
  (** The minimal slice of a Menhir [INCREMENTAL_ENGINE] the resolution needs:
      reaching a stack cell by depth and reading its source span. Instantiate it
      from the parser's [MenhirInterpreter] — [get] is [MenhirInterpreter.get]
      and [positions] destructures [MenhirInterpreter.Element]. *)

  type 'a env
  type element

  val get : int -> 'a env -> element option
  (** [get i env] is the [i]-th stack cell from the top (0-based), or [None]
      when the stack is shallower than [i]. This is [MenhirInterpreter.get]. *)

  val positions : element -> Lexing.position * Lexing.position
  (** The source span [(start, stop)] a stack cell covers. Destructure the
      engine's [Element (_, _, start, stop)]. *)
end

module Make (E : ENGINE) : sig
  type label = {
    loc_start : Lexing.position;
    loc_end : Lexing.position;
    text : string;
  }
  (** A resolved delimiter marker: a one-character span at the opening
      delimiter, and the marker's own label text (the ['<N>'] and its bounds
      removed). *)

  val resolve : source:string -> env:'a E.env -> string -> string * label list
  (** [resolve ~source ~env message] post-processes a stele-generated [message]
      against the error environment [env] and the whole source text [source]: it
      expands any Menhir [$i] source-slice references, then turns each [<N>…]
      marker line into a {!label} anchored at the [N]-th stack cell's opening
      delimiter (walking back over blanks to the [(] / [\[] / [{] when the
      cell's own start is not itself the delimiter). Returns the main message
      (marker lines removed) and the located labels in source order. A marker
      whose depth exceeds the live stack is left inline in the main message. *)
end
