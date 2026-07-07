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

val utf16_decode : int list -> string option
(** [utf16_decode units] is the UTF-8 string the UTF-16 [units] (each a 16-bit
    value) encode — the inverse of {!utf16_code_units} — pairing surrogates.
    [None] if a surrogate is unpaired. *)

val scalar_of_hex : string -> Uchar.t option
(** [scalar_of_hex s] decodes the hex digits [s] (the payload of a [\u{...}]
    escape) to a Unicode scalar value. [None] if [s] is not valid hex, overflows
    a native int, or is out of the scalar range (above U+10FFFF or a surrogate).
*)

val escape_string : ?hex_prefix:string -> string -> int * string
(** [escape_string s] returns a pair [(len, escaped)] where [escaped] is the
    escaped version of [s] suitable for WAT/Wax string literals, and [len] is
    its display length.

    Byte escapes are written [\HH] by default; [hex_prefix] is inserted after
    the backslash, so [~hex_prefix:"x"] produces Rust-style [\xHH] escapes for
    Wax. *)
