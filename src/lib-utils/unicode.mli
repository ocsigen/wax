val terminal_width : ?offset:int -> string -> int
(** [terminal_width s] returns the width of the string [s] when displayed in a
    terminal.

    The optional argument [offset] (default 0) specifies the starting column
    position, which is used to correctly calculate the width of tab characters.
*)

val expand_tabs : ?offset:int -> string -> string
(** [expand_tabs s] returns a copy of [s] where tab characters are replaced by
    spaces, assuming a tab width of 8.

    The optional argument [offset] (default 0) specifies the starting column
    position. *)

val utf16_code_units : string -> int list
(** [utf16_code_units s] is the sequence of UTF-16 code units (each a 16-bit
    value) encoding the valid-UTF-8 string [s]; a scalar outside the basic
    multilingual plane becomes a surrogate pair (two units). *)
