type t
(** A namespace manages a set of unique names, avoiding collisions with reserved
    keywords and previously allocated names. *)

val make : ?kind:[ `Regular | `Label | `Type ] -> unit -> t
(** Create a new namespace. [kind] determines the set of reserved words (default
    [`Regular]):
    - [`Regular]: Standard reserved keywords (e.g., "if", "loop").
    - [`Label]: No reserved words (empty).
    - [`Type]: Reserved keywords plus abstract heap types (e.g., "func", "any").
*)

val dup : t -> t
(** [dup t] returns a copy of the namespace [t]. Changes to the new namespace
    will not affect [t]. *)

val add : t -> string -> string
(** [add t name] registers [name] in the namespace [t]. If [name] is already
    taken or reserved, a unique suffix is appended (e.g., "name_1", "name_2").
    Returns the unique name that was actually registered. *)

type outcome =
  | Available  (** [name] was free and registered as-is. *)
  | Renamed of { reserved : bool; previous : Utils.Ast.location option }
      (** [name] was taken and a suffix was appended. [reserved] is true when
          the requested name is a reserved word, false when it collided with
          another registered name. [previous] is the location the colliding name
          was first claimed from, when one was recorded (always [None] for a
          reserved word). *)

val add' : ?loc:Utils.Ast.location -> t -> string -> string * outcome
(** Like {!add}, but also reports whether the name was renamed and, if so,
    whether the collision was with a reserved word and where the colliding name
    was previously claimed. [loc] records this name's source location, so a
    later collision with it can point back here. *)

val reserve : t -> string -> unit
(** [reserve t name] reserves [name] in the namespace [t]. If [name] is already
    taken or reserved, nothing happens. If it is free, it is marked as taken.
    This is useful to prevent subsequent [add] calls from generating this name.
*)
