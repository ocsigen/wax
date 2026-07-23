(** Runtime resolution of the [<N>] / [<^N>] markers stele's generated messages
    carry.

    A stele-generated message may embed marker lines of two kinds, both anchored
    at a 1-based stack cell index [N] resolved against the running parser:
    - a {b delimiter hint} [<N>This '(' opens the enclosing construct.] —
      underlines the opening delimiter of the construct at cell [N], spanning
      the full alias the label names (one character for a plain [(], both
      characters of a compound opener like [\[|]);
    - a {b hedge subject} [<^N>this expression] — underlines the {e whole}
      construct that cell [N] produced, the one a hedge ("Assuming that the X is
      complete, …") assumes finished.

    Resolving either needs the running parser's environment, so the generator (a
    build-time tool) cannot do it — the adopter's error handler must, at the
    point it holds the incremental engine's [env]. This library is that
    resolution, extracted once so every adopter shares the subtle half (the
    walk-back-over-blanks-to-the-opening-delimiter refinement, the epsilon
    subject handling) rather than reimplementing it.

    A consumer reading an older generator's output sees only [<N>] markers; a
    generator carrying [<^N>] markers stays readable to a resolver that predates
    them (the [^]-tagged depth fails the plain integer parse and the line is
    left inline), so the marker vocabulary extends compatibly.

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
  (** A resolved marker and its own label text (the marker prefix and its bounds
      removed): a delimiter hint gives a span at the opening delimiter as wide
      as the alias its label names (one character for a plain [(], two for a
      compound [\[|]), a hedge subject the whole construct's true span (rendered
      as a multi-line spine when it crosses several lines). *)

  val resolve : source:string -> env:'a E.env -> string -> string * label list
  (** [resolve ~source ~env message] post-processes a stele-generated [message]
      against the error environment [env] and the whole source text [source]: it
      expands any Menhir [$i] source-slice references, then turns each marker
      line into a {!label}:
      - [<N>…] anchors at the [N]-th stack cell's opening delimiter (walking
        back over blanks to the [(] / [\[] / [{] when the cell's own start is
        not itself the delimiter);
      - [<^N>…] anchors across the [N]-th stack cell's full span (the whole
        construct, however many lines it crosses), and {e dropped} when that
        span is zero-width (an epsilon reduction — no construct to point at).

      Returns the main message (marker lines removed) and the located labels in
      the order the markers appear (subject before delimiter hint, matching the
      generator's emission). A marker whose depth exceeds the live stack, or
      whose depth field it does not recognise, is left inline in the main
      message. *)
end
