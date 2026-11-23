(** 32-bit unsigned integers. *)

type t
(** The type of 32-bit unsigned integers. *)

val of_string : string -> t
(** [of_string s] parses a 32-bit unsigned integer from its decimal
    representation. *)

val to_string : t -> string
(** [to_string n] returns the decimal representation of [n]. *)

val of_int : int -> t
(** [of_int n] converts an OCaml [int] to a 32-bit unsigned integer. *)

val to_int : t -> int
(** Convert to an OCaml [int]. May raise if the value doesn't fit. *)

val to_int32 : t -> int32
(** Convert to an OCaml [int32]. *)

val of_int32 : int32 -> t
(** Convert from an OCaml [int32]. *)

val zero : t
(** The value 0. *)

val one : t
(** The value 1. *)

val succ : t -> t
(** [succ n] returns [n + 1]. *)

val add : t -> t -> t
(** [add n1 n2] returns [n1 + n2] modulo 2^32. *)

val compare : t -> t -> int
(** [compare n1 n2] compares [n1] and [n2]. *)
