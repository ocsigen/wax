(** Lexer for Wasm Text Format (WAT). *)

val token :
  Wax_utils.Trivia.context ->
  (Sedlexing.lexbuf -> Tokens.token) * Lexing.position option ref
(** [token ctx] returns the tokenizer closure and a [start_override] ref. After
    each call to the closure the ref holds [Some p] when the token just returned
    should start at [p] rather than at the lexbuf's reported start — used for
    the compound openers ([(param], [(then], …), whose [(] is lexed before the
    keyword. The supplier (see {!Wax_wasm.Parsing}) consults it. *)

val is_valid_identifier : string -> bool
