(** Generic parsing utilities. *)

exception Syntax_error of (Lexing.position * Lexing.position) * string
(** Exception raised when a syntax error occurs, with location range and
    message. *)

type syntax_error = {
  location : Wax_utils.Ast.location;
  message : string;
  related : Wax_utils.Diagnostic.label list;
}
(** A syntax error returned as data by {!Make_parser.parse_diagnostics}: the
    location range, the human-readable message, and any related labels (e.g. the
    matching opening delimiter). *)

(** Functor to create a parser from a Menhir incremental API. *)
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
      without printing or exiting, and without the fast parser (the incremental
      parser produces both the AST and the error in a single pass). For
      in-process use — e.g. an editor that wants the syntax error as data to
      report as a diagnostic — where the print-and-exit behaviour of
      {!parse_from_string} is unwanted. *)
end
