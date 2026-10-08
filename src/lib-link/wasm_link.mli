(** Merge several WebAssembly binary modules into one.

    Every input import is resolved against the exports of the whole set: a
    resolved import turns into an internal reference, an unresolved one is
    re-emitted as an import of the merged module. Types are deduplicated across
    modules and every index space (type, function, table, memory, global, tag,
    element, data) is renumbered into the single output module. The name
    section, the [metadata.code.*] hint sections of the branch-hinting and
    compilation-hints proposals, and per-module source maps are rewritten to
    follow the new layout and byte offsets. *)

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

type dependency = {
  name : string;
  export : string option;
  import : (string * string) option;
  reaches : string list;
  root : bool;
}
(** A node of the dependency graph used for dead code elimination, in the format
    of binaryen's [wasm-metadce]: [export] and [import] associate the node with
    an export and an import of the linked module; [reaches] lists the nodes this
    node depends on (by name). *)

val parse_dependencies : string -> dependency list
(** Parse a dependency graph in the JSON format of [wasm-metadce]: a list of
    objects with a [name] field and optional [export], [import] (a pair
    [[module, name]]), [reaches] (a list of node names) and [root] fields.
    Raises [Yojson.Json_error] or [Yojson.Basic.Util.Type_error] on malformed
    input. *)

val f :
  ?rename_export:(string -> string -> string option) ->
  ?distinct_named_types:bool ->
  ?dependencies:dependency list ->
  ?names:bool ->
  ?source_map:bool ->
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

    [source_map] (default [false]) also writes the returned map to
    [output_file ^ ".map"] and appends a [sourceMappingURL] custom section
    naming it, the pair of artifacts [wax --source-map] produces for a binary
    output. The map is returned either way, so a caller that places it itself
    (under another name, or in memory) leaves this off.

    With [dependencies], dead code is removed: only the exports reachable from
    the root nodes of the dependency graph are kept (identified by their name in
    the merged module), an import node being reached when the corresponding
    import is used, and only the functions, globals, tags, types, passive data
    segments and imports reachable from these exports or from the start
    functions are kept. Declarative element segments, and passive ones that are
    not used, only keep the functions that are reachable otherwise. Removing
    dead code changes neither tables, memories, nor active segments.

    [names] (default [true]) controls whether the name section is emitted.

    [distinct_named_types] (default [false]) makes type deduplication
    name-aware: two structurally-equal types are coalesced into one output type
    only when they also share the same type name and field names; otherwise the
    later one is emitted as a separate, structurally-identical copy so its names
    survive. Off by default, matching wasm-merge's purely structural merge. *)

val imports : string -> (string * string) list
(** The imports of a Wasm module, as pairs (module name, name). *)

val get_instruction_offsets : filename:string -> string -> int list * int
(** [get_instruction_offsets ~filename buf] returns the byte offset of every
    instruction in the code section of the binary [buf], together with the
    number of functions. Used by the source-map checker to align mappings with
    instruction boundaries; not part of the linking path. *)
