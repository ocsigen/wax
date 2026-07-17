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
