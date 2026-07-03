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
