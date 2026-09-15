(* A single (non-indexed) source map, as read from a [.map] file. Opaque: the
   linker only carries it from [of_file] through [resize] to [concatenate]. *)
module Standard : sig
  type t

  val of_file : ?tmp_buf:Buffer.t -> string -> t
  val of_string : ?tmp_buf:Buffer.t -> string -> t
end

(* The linked output's source map: the indexed form produced by [concatenate]. *)
type t

val to_file : t -> string -> unit
val to_string : t -> string

val iter_sources : t -> (int option -> int option -> string -> unit) -> unit
(** [iter_sources m f] calls [f section source name] on every source file the
    map names, where [section] and [source] are the indices of the section and
    of the source within it, each [None] when there is only one of them to
    name. An embedder that copies the sources next to the map uses the pair to
    build each one's filename. *)

(* A sequence of [(pos, delta)] byte-shift entries with strictly increasing
   [pos], describing how the code section grew/shrank when instructions were
   re-encoded during linking. Built imperatively by the code scan, hence the
   mutable growable arrays; [i] is the number of live entries. *)
type resize_data = {
  mutable i : int;
  mutable pos : int array;
  mutable delta : int array;
}

val is_empty : Standard.t -> bool

(* [resize_mappings data m] rewrites the VLQ "mappings" string [m], shifting each
   generated column by the cumulative [data] delta at that column and dropping a
   segment whose column would become negative (folding its source/name deltas
   into the next survivor). Exposed for testing. *)
val resize_mappings : resize_data -> string -> string
val resize : resize_data -> Standard.t -> Standard.t

(* Combine per-module maps, each offset by its code-section start, into one
   indexed source map for the linked output. *)
val concatenate : (int * Standard.t) list -> t
