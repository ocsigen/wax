val header : string

type ch = {
  filename : string option;
  buf : string;
  mutable pos : int;
  limit : int;
  mutable has_data_count : bool;
  diagnostics : Wax_utils.Diagnostic.context;
  features : Wax_utils.Feature.set;
}

val make_ch :
  Wax_utils.Diagnostic.context -> ?filename:string -> string -> int -> ch

val pos_in : ch -> int
val seek_in : ch -> int -> unit
val uint : ?n:int -> ch -> int
val check_header : ch -> unit
val name : ch -> string
val tabletype : ch -> Ast.Binary.tabletype
val globaltype : ch -> Ast.Binary.globaltype
val type_section : ch -> Ast.Binary.subtype array array
val import_section : ch -> Ast.Binary.import_entry list
val export_section : ch -> Ast.Binary.export array
val function_section : ch -> int array
val memory_section : ch -> Ast.Binary.limits array
val tag_section : ch -> int array
val start_section : ch -> int
val datacount_section : ch -> int
val namemap : ch -> (int * string) array
val indirect_namemap : ch -> (int * (int * string) array) array
val branch_hint_section : ch -> (int * (int * bool) list) array

type section = { id : int; pos : int; size : int }

module IntHashtbl : Hashtbl.S with type key = int
module StringHashtbl : Hashtbl.S with type key = string

type index = {
  sections : section IntHashtbl.t;
  custom_sections : section StringHashtbl.t;
}

val index : ch -> index
val find_section : ch -> index -> int -> bool
val get_custom_section : index -> string -> section option
val focus_on_custom_section : ch -> index -> string -> ch * index

val module_ :
  Wax_utils.Diagnostic.context ->
  ?features:Wax_utils.Feature.set ->
  ?filename:string ->
  string ->
  Ast.location Ast.Binary.module_
(** [module_ diagnostics ?filename buf] decodes the Wasm binary [buf]. Malformed
    input is reported to [diagnostics] (anchored at the offending byte offset)
    and parsing is aborted via {!Wax_utils.Diagnostic.abort}. Gated encodings
    (an optional proposal's constructs) are always accepted; each is recorded on
    [features] via {!Wax_utils.Feature.mark_used}, so the caller can learn which
    proposals the module exercises. *)
