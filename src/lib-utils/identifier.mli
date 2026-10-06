val is_valid : string -> bool
(** Whether a string is a valid Wax identifier, lexically: keywords included.
    Shared by the Wax lexer and the WAT side, where a conditional-compilation
    variable must be one, as it is named the same way in Wax. *)
