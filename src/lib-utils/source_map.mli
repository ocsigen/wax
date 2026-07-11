(* Base64 VLQ, the integer encoding used by source-map "mappings". *)
module Vlq64 : sig
  val in_alphabet : char -> bool

  type input = { string : string; mutable pos : int; len : int }

  val encode : Buffer.t -> int -> unit
  val encode_l : Buffer.t -> int list -> unit
  val decode : input -> int
  val decode_l : string -> pos:int -> len:int -> int list
end

type t

type mapping = {
  generated_offset : int;
  original_file_idx : int;
  original_line : int;
  original_column : int;
}

val create : enabled:bool -> t
(** [create ~enabled:false] returns a sink whose recording functions are no-ops,
    so a module writer that never serializes a map does not pay for accumulating
    one entry per instruction. *)

val register_file : t -> string -> int

val add_mapping :
  t -> generated_offset:int -> original_location:Ast.location -> unit
(** Map [generated_offset] to the {e start} of [original_location]. *)

val add_mapping_at :
  t -> generated_offset:int -> position:Lexing.position -> unit
(** Map [generated_offset] to a specific source [position] — used to attach the
    closing [end] opcode of a block or expression to its end position. *)

val add_absent_mapping : t -> generated_offset:int -> unit
(** [add_absent_mapping t ~generated_offset] records that the code at
    [generated_offset] has no original location, emitting a segment that resets
    the mapping so the previous location does not bleed into it. *)

type checkpoint

val checkpoint : t -> checkpoint
(** [checkpoint t] captures the set of mappings recorded so far, for a later
    {!shift_since}. Mappings are recorded with generated offsets relative to
    whichever buffer is being encoded; a checkpoint plus {!shift_since} rebases
    the ones added afterwards once their absolute file offset is known. *)

val shift_since : t -> checkpoint -> delta:int -> unit
(** [shift_since t cp ~delta] adds [delta] to the generated offset of every
    mapping recorded since the checkpoint [cp]. *)

val to_json : t -> file_name:string -> string
