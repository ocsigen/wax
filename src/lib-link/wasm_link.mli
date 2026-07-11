type input = {
  module_name : string;
  file : string;
  code : string option;
  opt_source_map : Source_map.Standard.t option;
}

val f :
  ?filter_export:(string -> bool) ->
  ?distinct_named_types:bool ->
  input list ->
  output_file:string ->
  Source_map.t
(** [distinct_named_types] (default [false]) makes type deduplication
    name-aware: two structurally-equal types are coalesced into one output type
    only when they also share the same type name and field names; otherwise the
    later one is emitted as a separate, structurally-identical copy so its names
    survive. Off by default, matching wasm-merge's purely structural merge. *)

val get_instruction_offsets : filename:string -> string -> int list * int
