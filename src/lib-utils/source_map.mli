type t

type mapping = {
  generated_offset : int;
  original_file_idx : int;
  original_line : int;
  original_column : int;
}

val create : unit -> t
val register_file : t -> string -> int

val add_mapping :
  t -> generated_offset:int -> original_location:Ast.location -> unit

val add_absent_mapping : t -> generated_offset:int -> unit
(** [add_absent_mapping t ~generated_offset] records that the code at
    [generated_offset] has no original location, emitting a segment that resets
    the mapping so the previous location does not bleed into it. *)

val to_json : t -> file_name:string -> string
