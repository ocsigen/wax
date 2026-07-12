val module_ :
  out_channel:out_channel ->
  ?output_file:string ->
  ?source_map:bool ->
  Ast.location Ast.Binary.module_ ->
  unit
(** [?output_file] is the name of the binary being written (when not stdout); it
    names the generated file in the emitted source map's [file] field. *)

val to_string : ?output_file:string -> Ast.location Ast.Binary.module_ -> string
(** As {!module_}, but returns the binary as an in-memory string (no channel, no
    source map). For in-process embedders — e.g. the MCP convert tool — that
    need the bytes without a file. *)
