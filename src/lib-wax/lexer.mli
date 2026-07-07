(** Lexer for Wax. *)

val is_valid_identifier : string -> bool
(** Checks if a string is a valid Wax identifier. *)

val token :
  Wax_utils.Trivia.context ->
  (Sedlexing.lexbuf -> Tokens.token) * Lexing.position option ref
(** [token ctx] returns the tokenizer closure and a [start_override] ref (always
    [None] here — the Wax lexer combines no tokens). The shape matches the
    shared lexer interface consumed by {!Wax_wasm.Parsing}; see
    {!Wax_wasm.Lexer.token}. *)
