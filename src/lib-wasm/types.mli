(** Type handling for Wasm. *)

module Id : sig
  type t
  (** The canonical index of a type: the currency returned by {!add_rectype} and
      required by {!get_subtype}, and the index the internal type representation
      ({!Internal}) carries for its references. Fully abstract — there is no
      [of_int]/[to_int] — so outside this module an [Id.t] can only be obtained
      from the store, never fabricated from or confused with a source-level or
      wire-level integer. *)

  val equal : t -> t -> bool

  val add : t -> int -> t
  (** [add id n] is the canonical index [n] positions after [id] (e.g. the
      [n]-th member of a rec group whose first member is [id]). *)

  val to_int_for_tests_only : t -> int
  (** The underlying integer. For tests that render an index; not for production
      code, which must treat {!t} as opaque. *)
end

module Internal : sig
  (** The internal (resolved) type representation: type references carry the
      abstract {!Id.t} rather than the wire format's [int]. This is what the
      type store and validation reason about; the codec stays on {!Ast.Binary}.
  *)

  module X : sig
    type idx = Id.t
    type 'a annotated_array = 'a array
    type 'a opt_annotated_array = 'a array
  end

  include module type of Ast.Make_types (X)

  type tabletype = { limits : limits; reftype : reftype }
end

type ref_index =
  | Def of Id.t
  | Rec of int
      (** A reference inside a rec group being registered ({!Normalized}):
          [Def id] denotes an already-defined type by its canonical index, while
          [Rec pos] denotes the group's own [pos]-th member. Making the
          intra-group back-reference a constructor — rather than a canonical
          index and a negative sign bit sharing one integer space — means the
          two cannot be confused, and an [Id.t] is only ever a genuine store
          index. *)

module Normalized : sig
  (** The normalized form fed to {!add_rectype}: like {!Internal}, but
      references are {!ref_index} so a rec group's own members are named
      relatively (by position) and the group dedups regardless of where it
      lands. A caller resolving a source rec group builds this directly. *)

  module X : sig
    type idx = ref_index
    type 'a annotated_array = 'a array
    type 'a opt_annotated_array = 'a array
  end

  include module type of Ast.Make_types (X)
end

type t
(** A type context holding recursive type definitions. *)

val create : unit -> t
(** [create ()] creates a new empty type context. *)

val add_rectype : t -> Normalized.rectype -> Id.t
(** Add a recursive type definition to the context. Returns the canonical index
    of the first type defined. Raises [Invalid_argument] if the group is not
    well-formed (a [Rec] back-reference out of range, or a [Def] referring to a
    type not yet defined). *)

val last_index : t -> int
(** [last_index context] returns the index that the next freshly-added type
    would receive (i.e. the number of types currently defined). *)

type subtyping_info
(** Information needed for subtyping checks. *)

val subtyping_info : t -> subtyping_info
(** [subtyping_info context] extracts subtyping information from the context. *)

val get_subtype : subtyping_info -> Id.t -> Internal.subtype
(** [get_subtype info index] returns the subtype at the given canonical index.
*)

val get_all_rectypes : t -> Internal.rectype list
(** Returns all recursive type definitions from the context. *)

val heap_subtype :
  subtyping_info -> Internal.heaptype -> Internal.heaptype -> bool
(** [heap_subtype info ht1 ht2] checks if [ht1] is a subtype of [ht2]. *)

val ref_subtype : subtyping_info -> Internal.reftype -> Internal.reftype -> bool
(** [ref_subtype info rt1 rt2] checks if [rt1] is a subtype of [rt2]. *)

val val_subtype : subtyping_info -> Internal.valtype -> Internal.valtype -> bool
val heaptype_equal : Internal.heaptype -> Internal.heaptype -> bool
val reftype_equal : Internal.reftype -> Internal.reftype -> bool

val valtype_equal : Internal.valtype -> Internal.valtype -> bool
(** [val_subtype info vt1 vt2] checks if [vt1] is a subtype of [vt2]. *)
