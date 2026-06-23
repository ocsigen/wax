(** Lexer for Wasm Text Format (WAT). *)

val token : Wax_utils.Trivia.context -> Sedlexing.lexbuf -> Tokens.token
val is_valid_identifier : string -> bool
