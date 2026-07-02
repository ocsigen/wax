(** 64-bit unsigned integers. *)

type t
(** The type of 64-bit unsigned integers. *)

val of_string : string -> t
(** [of_string s] parses a 64-bit unsigned integer from its decimal
    representation. *)

val to_string : t -> string
(** [to_string n] returns the decimal representation of [n]. *)

val of_int : int -> t
(** [of_int n] converts an OCaml [int] to a 64-bit unsigned integer. *)

val to_int : t -> int
(** Convert to an OCaml [int]. The caller must ensure the value fits (bound it
    first); an unguarded call that overflows is a bug, and this asserts. *)

val to_int64 : t -> int64
(** Convert to an OCaml [int64]. *)

val of_int64 : int64 -> t
(** Convert from an OCaml [int64]. *)

val zero : t
(** The value 0. *)

val one : t
(** The value 1. *)

val compare : t -> t -> int
(** [compare n1 n2] compares [n1] and [n2]. *)
