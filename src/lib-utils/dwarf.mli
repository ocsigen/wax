val generate :
  source_map:Source_map.t ->
  code_payload_start:int ->
  func_layouts:(int, int * int) Hashtbl.t ->
  source_filename:string ->
  (string * string) list
(** [generate ~source_map ~code_payload_start ~func_layouts ~source_filename]
    returns the list of custom section names and their byte contents. The line
    table is built from the file-absolute mappings recorded in [source_map],
    bucketed into function bodies by [func_layouts] (function index to its
    body's file offset and size) and rebased against [code_payload_start] (the
    file offset of the code section payload). *)
