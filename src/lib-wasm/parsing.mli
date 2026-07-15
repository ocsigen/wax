(** Generic parsing utilities. *)

exception
  Syntax_error of (Lexing.position * Lexing.position) * Wax_utils.Message.t
(** Exception raised when a syntax error occurs, with location range and
    message. *)

type syntax_error = {
  location : Wax_utils.Ast.location;
  message : Wax_utils.Message.t;
  related : Wax_utils.Diagnostic.label list;
}
(** A syntax error returned as data by [parse_diagnostics]: the location range,
    the human-readable message, and any related labels (e.g. the matching
    opening delimiter). *)

type sync_class =
  | Open
  | Close
  | Boundary
  | Leader
  | Terminal
  | Skip
      (** How the panic-mode recovery of {!Make.parse_recover} treats a token
          when it is scanning for a place to resynchronize. The skip is
          nesting-aware: it tracks the bracket depth entered {e while skipping}
          so a boundary belonging to a group opened inside the skipped span does
          not resynchronize the enclosing construct.

          - [Open] — an opening bracket. Descends one nesting level; never
            itself a resync point.
          - [Close] — a closing bracket. At the outer level (depth 0) it is a
            resync point closing an enclosing construct; otherwise it ascends
            one level (matching an [Open] met while skipping) and scanning
            continues.
          - [Boundary] — a non-bracket resync point (typically a statement
            separator), counted only at the outer level, like a [Close].
            Recovery stops there, unwinds the parser stack to the closest state
            that can shift it, shifts it, and resumes.
          - [Leader] — a resync point valid at {e any} depth: an
            item/statement-leading keyword. Recovery stops at one even inside an
            unbalanced opener, so a stray bracket cannot swallow the next
            top-level item.
          - [Terminal] — the end-of-input token. Recovery stops at it but never
            discards it; if no stacked state can accept it, parsing gives up
            (the best-effort AST is then absent).
          - [Skip] — anything else: discarded while scanning for the next
            boundary. *)

(** Core parser over a Menhir incremental API, {e without} the fast parser. The
    incremental parser produces both the AST and, via [Parser_messages], the
    error in a single pass, so this is all an in-process consumer that only
    wants [parse_diagnostics] needs. See {!Make_parser} for the fast-path
    variant. *)
module Make (Output : sig
  type t
end) (Tokens : sig
  type token
end) (_ : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    module MenhirInterpreter :
      MenhirLib.IncrementalEngine.INCREMENTAL_ENGINE with type token = token

    module Incremental : sig
      val parse : Lexing.position -> Output.t MenhirInterpreter.checkpoint
    end
  end
end) (_ : sig
  val message : int -> string
end) (_ : sig
  val token :
    Wax_utils.Trivia.context ->
    (Sedlexing.lexbuf -> Tokens.token) * Lexing.position option ref
end) : sig
  val parse :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    unit ->
    Output.t * Wax_utils.Trivia.context
  (** Parse a file from a filename (reads from stdin if filename is empty or
      "-"). On a syntax error the diagnostic is printed and {!Syntax_error} is
      raised; the caller decides how to terminate (the CLI exits 128). *)

  val parse_from_string :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    string ->
    Output.t * Wax_utils.Trivia.context
  (** Parse from a string. On a syntax error the diagnostic is printed and
      {!Syntax_error} is raised; the caller decides how to terminate (the CLI
      exits 128). *)

  val parse_diagnostics :
    filename:string ->
    string ->
    (Output.t * Wax_utils.Trivia.context, syntax_error) result
  (** Parse from a string, returning [Ok (ast, context)] or [Error error]
      without printing or exiting. For in-process use — e.g. an editor that
      wants the syntax error as data to report as a diagnostic — where the
      print-and-exit behaviour of {!parse_from_string} is unwanted. *)

  val parse_recover :
    filename:string ->
    sync:(Tokens.token -> sync_class) ->
    ?insert:(Tokens.token * Wax_utils.Message.t) list ->
    ?closers:Tokens.token list ->
    ?barrier:Tokens.token * (Tokens.token -> bool) * (Tokens.token -> bool) ->
    string ->
    Output.t option * syntax_error list * Wax_utils.Trivia.context
  (** Parse with panic-mode error recovery, collecting {e every} syntax error
      instead of stopping at the first. On each error the parser stack is
      resynchronized: tokens are discarded up to the next boundary (as
      classified by [sync]), the stack is unwound to the closest state that can
      shift that boundary, the boundary is shifted, and parsing resumes; see
      {!sync_class}. A lexer error (bad character, malformed byte) is likewise
      recorded and skipped, so a stray character does not truncate the parse.
      Returns the best-effort AST ([Some ast] if parsing reached an accepting
      state, [None] if recovery could not), the errors in source order, and the
      trivia context. Nothing is printed. Intended for in-process consumers such
      as a language server that must report all errors and keep a partial AST
      across them.

      [insert] is a list of candidate tokens (each with the diagnostic to
      report) that recovery may {e insert} in front of an offending token
      instead of skipping to a boundary — a statement separator like [;], or a
      placeholder operand like a zero [0] that lets an incomplete construct
      complete. The candidates are tried in order; the engine's [acceptable]
      answers whether one fits, and the repair is kept only if the offending
      token then shifts too (validated, so a wrong guess is discarded).
      Insertion is attempted at most once per source position, so it cannot
      loop; it falls back to skip-based recovery. The candidates also serve
      [close_pending] (e.g. completing an unclosed construct at EOF). Omit
      ([[]]) to disable insertion.

      [closers] lists the closing-bracket tokens. At end of input inside an
      unclosed bracketed construct, recovery auto-closes: it inserts whichever
      of these the parser accepts (and, between them, the [insert] separator
      when a statement must be terminated first), repeatedly, until EOF is
      accepted, so the construct the user is still typing reduces into the
      best-effort AST instead of being unwound away and dropped. The syntax
      error is still reported; only the recovered AST improves. Omit to keep the
      unwind-and-discard behaviour. *)
end

(** {!Make} plus a fast parser, whose only role is speed on the happy path:
    [parse_from_string] tries it and, on a syntax error, falls back to the
    core's incremental parser to produce the message. Same result signature as
    {!Make}. The CLI uses this; an in-process consumer can use {!Make} directly.
*)
module Make_parser (Output : sig
  type t
end) (Tokens : sig
  type token
end) (_ : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    module MenhirInterpreter :
      MenhirLib.IncrementalEngine.INCREMENTAL_ENGINE with type token = token

    module Incremental : sig
      val parse : Lexing.position -> Output.t MenhirInterpreter.checkpoint
    end
  end
end) (_ : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    exception Error

    val parse : (Lexing.lexbuf -> token) -> Lexing.lexbuf -> Output.t
  end
end) (_ : sig
  val message : int -> string
end) (_ : sig
  val token :
    Wax_utils.Trivia.context ->
    (Sedlexing.lexbuf -> Tokens.token) * Lexing.position option ref
end) : sig
  val parse :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    unit ->
    Output.t * Wax_utils.Trivia.context
  (** As {!Make.parse}, using the fast parser on the happy path. *)

  val parse_from_string :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    string ->
    Output.t * Wax_utils.Trivia.context
  (** As {!Make.parse_from_string}, using the fast parser on the happy path. *)

  val parse_diagnostics :
    filename:string ->
    string ->
    (Output.t * Wax_utils.Trivia.context, syntax_error) result
  (** As {!Make.parse_diagnostics}. *)

  val parse_recover :
    filename:string ->
    sync:(Tokens.token -> sync_class) ->
    ?insert:(Tokens.token * Wax_utils.Message.t) list ->
    ?closers:Tokens.token list ->
    ?barrier:Tokens.token * (Tokens.token -> bool) * (Tokens.token -> bool) ->
    string ->
    Output.t option * syntax_error list * Wax_utils.Trivia.context
  (** As {!Make.parse_recover}. (Recovery always uses the incremental engine;
      there is no fast-path variant.) *)
end
