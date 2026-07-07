(** Generic AST definitions. *)

type ('desc, 'info) annotated = { desc : 'desc; info : 'info }
(** A value of type ['desc] annotated with extra information of type ['info]
    (e.g., source location). *)

type location = { loc_start : Lexing.position; loc_end : Lexing.position }
(** A source code location range. *)

val dummy_loc : location
(** A location with dummy start/end positions, for synthesized nodes. *)

val no_loc : 'desc -> ('desc, location) annotated
(** [no_loc v] wraps [v] with a dummy location. *)

val concat_desc : (string, 'info) annotated list -> string
(** [concat_desc l] concatenates the string [desc] of each element of [l] — e.g.
    the pieces of a multi-string [datastring] such as [(data "a" "b")]. *)
