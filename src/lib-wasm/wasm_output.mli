val module_ :
  out_channel:out_channel ->
  ?output_file:string ->
  ?source_map:bool ->
  Ast.location Ast.Binary.module_ ->
  unit
(** [?output_file] is the name of the binary being written (when not stdout); it
    names the generated file in the emitted source map's [file] field. *)
