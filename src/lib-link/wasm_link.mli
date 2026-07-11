(** Merge several WebAssembly binary modules into one.

    Every input import is resolved against the exports of the whole set: a
    resolved import turns into an internal reference, an unresolved one is
    re-emitted as an import of the merged module. Types are deduplicated across
    modules and every index space (type, function, table, memory, global, tag,
    element, data) is renumbered into the single output module. The name
    section, branch hints and per-module source maps are rewritten to follow the
    new layout and byte offsets. *)

type input = {
  module_name : string;
      (** Name under which this module's exports are published; the imports of
          the other inputs resolve against it. *)
  file : string;
      (** Path of the module, used in diagnostics and to read [code] when it is
          [None]. *)
  code : string option;  (** The module bytes, or [None] to read [file]. *)
  opt_source_map : Source_map.Standard.t option;
      (** Source map for this module's code section, merged into the result. *)
}

val f :
  ?rename_export:(string -> string -> string option) ->
  ?distinct_named_types:bool ->
  input list ->
  output_file:string ->
  Source_map.t
(** [f inputs ~output_file] writes the merged binary to [output_file] and
    returns its source map (empty unless some input carried one). A link error
    (incompatible import/export, duplicate export, unresolvable forward
    reference) is reported through {!Wax_utils.Diagnostic} and aborts.

    [rename_export module_name export_name] gives the name that export should
    carry in the merged module, or [None] to drop it (default: keep every export
    unchanged). Being told the defining module's name lets the caller keep the
    exports of one input only, or rename otherwise-colliding exports of
    different inputs to distinct names so both survive.

    [distinct_named_types] (default [false]) makes type deduplication
    name-aware: two structurally-equal types are coalesced into one output type
    only when they also share the same type name and field names; otherwise the
    later one is emitted as a separate, structurally-identical copy so its names
    survive. Off by default, matching wasm-merge's purely structural merge. *)

val get_instruction_offsets : filename:string -> string -> int list * int
(** [get_instruction_offsets ~filename buf] returns the byte offset of every
    instruction in the code section of the binary [buf], together with the
    number of functions. Used by the source-map checker to align mappings with
    instruction boundaries; not part of the linking path. *)
