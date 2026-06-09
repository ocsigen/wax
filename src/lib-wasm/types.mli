(** Type handling for Wasm. *)

type t
(** A type context holding recursive type definitions. *)

val create : unit -> t
(** [create ()] creates a new empty type context. *)

val add_rectype : t -> Ast.Binary.rectype -> int
(** Add a recursive type definition to the context. Returns the index of the
    first type defined. Assumes normalized types (use negative numbers for
    recursive references). *)

val last_index : t -> int
(** [last_index context] returns the index that the next freshly-added type
    would receive (i.e. the number of types currently defined). *)

type subtyping_info
(** Information needed for subtyping checks. *)

val subtyping_info : t -> subtyping_info
(** [subtyping_info context] extracts subtyping information from the context. *)

val get_subtype : subtyping_info -> int -> Ast.Binary.subtype
(** [get_subtype info index] returns the subtype at the given index. *)

val get_all_rectypes : t -> Ast.Binary.rectype list
(** Returns all recursive type definitions from the context. *)

val heap_subtype :
  subtyping_info -> Ast.Binary.heaptype -> Ast.Binary.heaptype -> bool
(** [heap_subtype info ht1 ht2] checks if [ht1] is a subtype of [ht2]. *)

val ref_subtype :
  subtyping_info -> Ast.Binary.reftype -> Ast.Binary.reftype -> bool
(** [ref_subtype info rt1 rt2] checks if [rt1] is a subtype of [rt2]. *)

val val_subtype :
  subtyping_info -> Ast.Binary.valtype -> Ast.Binary.valtype -> bool
(** [val_subtype info vt1 vt2] checks if [vt1] is a subtype of [vt2]. *)
