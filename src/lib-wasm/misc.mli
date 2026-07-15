(** Miscellaneous utilities for validating Wasm values. *)

val is_int8 : string -> bool
(** Checks if string [s] represents a valid 8-bit integer. *)

val is_int16 : string -> bool
(** Checks if string [s] represents a valid 16-bit integer. *)

val is_int32 : string -> bool
(** Checks if string [s] represents a valid 32-bit integer. *)

val is_int64 : string -> bool
(** Checks if string [s] represents a valid 64-bit integer. *)

val is_float32 : string -> bool
(** Checks if string [s] represents a valid 32-bit float. *)

val is_float64 : string -> bool
(** Checks if string [s] represents a valid 64-bit float. *)

val encode_scalar : Ast.Text.storagetype -> string -> string
(** [encode_scalar ty s] is the little-endian byte encoding of the numeric
    literal [s] at scalar type [ty] (two's complement / IEEE-754). *)

val encode_dataval : Ast.Text.dataval -> string
(** The raw bytes of a data segment's contents (WAT numeric-values proposal):
    each element encoded little-endian and concatenated. *)

val dataval_byte_length : Ast.Text.dataval -> int
(** The byte length of a data segment's contents, without materializing it. *)
