(** Generic parsing utilities. *)

exception Syntax_error of (Lexing.position * Lexing.position) * string
(** Exception raised when a syntax error occurs, with location range and
    message. *)

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
      "-"). *)

  val parse_from_string :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    string ->
    Output.t * Wax_utils.Trivia.context
  (** Parse from a string. *)
end
