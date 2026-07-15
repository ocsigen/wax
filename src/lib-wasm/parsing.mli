(** Generic parsing utilities. *)

exception Syntax_error of (Lexing.position * Lexing.position) * string
(** Exception raised when a syntax error occurs, with location range and
    message. *)

type syntax_error = {
  location : Wax_utils.Ast.location;
  message : string;
  related : Wax_utils.Diagnostic.label list;
}
(** A syntax error returned as data by [parse_diagnostics]: the location range,
    the human-readable message, and any related labels (e.g. the matching
    opening delimiter). *)

type sync_class =
  | Boundary
  | Terminal
  | Skip
      (** How the panic-mode recovery of {!Make.parse_recover} treats a token
          when it is scanning for a place to resynchronize.

          - [Boundary] — a resynchronization point (typically [";"] or ["}"]).
            Recovery stops skipping when it reaches one, unwinds the parser
            stack to the closest state that can shift it, shifts it, and resumes
            parsing.
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
    string ->
    Output.t option * syntax_error list * Wax_utils.Trivia.context
  (** Parse with panic-mode error recovery, collecting {e every} syntax error
      instead of stopping at the first. On each error the parser stack is
      resynchronized: tokens are discarded up to the next boundary (as
      classified by [sync]), the stack is unwound to the closest state that can
      shift that boundary, the boundary is shifted, and parsing resumes; see
      {!sync_class}. Returns the best-effort AST ([Some ast] if parsing reached
      an accepting state, [None] if recovery could not), the errors in source
      order, and the trivia context. Nothing is printed. Intended for in-process
      consumers such as a language server that must report all errors and keep a
      partial AST across them. *)
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
    string ->
    Output.t option * syntax_error list * Wax_utils.Trivia.context
  (** As {!Make.parse_recover}. (Recovery always uses the incremental engine;
      there is no fast-path variant.) *)
end
