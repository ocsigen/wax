module Encoder : sig
  val uint : Buffer.t -> int -> unit
  val name : Buffer.t -> string -> unit
  val vec' : (Buffer.t -> 'a -> unit) -> Buffer.t -> 'a array -> unit
end

val module_ :
  out_channel:out_channel ->
  ?output_file:string ->
  ?source_map:bool ->
  ?coalesce_imports:bool ->
  ?features:Wax_utils.Feature.set ->
  Ast.location Ast.Binary.module_ ->
  unit
(** [?output_file] is the name of the binary being written (when not stdout); it
    names the generated file in the emitted source map's [file] field.
    [?features] gates output-side encoding choices. A group already in the AST
    is emitted verbatim either way (preserving the authorial layout of a text
    input, or an existing binary group). [?coalesce_imports] additionally
    coalesces maximal runs of ungrouped same-module imports into one group when
    compact-import-section is enabled; it is the binary-input compressor path
    (default [false]), off for text inputs whose import layout comes from their
    own group syntax. *)

(** Each [*_section] writer returns the number of content bytes written (as
    [output_section] does), so callers that track the running file position can
    account for it; [Wasm_link] uses them purely for their effect. *)

val type_section : out_channel -> Ast.Binary.rectype list -> int
val import_section : out_channel -> Ast.Binary.import_entry list -> int
val function_section : out_channel -> int list -> int
val memory_section : out_channel -> Ast.Binary.limits list -> int
val tag_section : out_channel -> int list -> int
val export_section : out_channel -> Ast.Binary.export list -> int
val start_section : out_channel -> int -> int
val datacount_section : out_channel -> int -> int

val output_code_metadata_section :
  out_channel -> string -> (int * (int * string) list) list -> int
(** [output_code_metadata_section ch name entries] writes the
    [metadata.code.<name>] custom section holding [entries], each a function
    index and its (byte offset, payload) pairs. Both levels must already be in
    increasing order, as the branch-hinting and compilation-hints proposals
    require. *)
