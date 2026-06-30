(** High-level conversion pipeline, reusable outside the [wax] command-line tool
    (e.g. as a preprocessor embedded in another compiler).

    Each entry point parses a source module, specializes its conditional
    annotations against [defines], and lowers it to the binary format. The same
    pipeline is implemented inline by the [wax] CLI; these functions package it
    so an embedder need not reproduce the parser instantiation and pass
    ordering. *)

type binary_module = Wax_wasm.Ast.location Wax_wasm.Ast.Binary.module_

val wat_to_binary :
  ?color:Wax_utils.Colors.flag ->
  ?defines:Wax_wasm.Cond_specialize.bindings ->
  ?name_functions:bool ->
  ?validate:bool ->
  filename:string ->
  string ->
  binary_module
(** [wat_to_binary ~filename contents] parses the WAT [contents], specializes
    its [(@if ...)] annotations against [defines] (default empty), optionally
    [validate]s it (default [false]), and lowers it to the binary format. When
    [name_functions] is set (default [false]), each anonymous exported function
    is named after its export (see
    {!Wax_wasm.Naming.name_functions_from_exports}) so it appears in the binary
    "name" section. Raises {!Wax_wasm.Text_to_binary.Conditional_in_binary} if a
    conditional annotation survived specialization, or
    {!Wax_wasm.Text_to_binary.Unresolved_reference} if a named index or label
    reference resolves to nothing. *)

val wax_to_binary :
  ?color:Wax_utils.Colors.flag ->
  ?defines:Wax_wasm.Cond_specialize.bindings ->
  ?validate:bool ->
  filename:string ->
  string ->
  binary_module
(** As {!wat_to_binary}, but the [contents] are in the Wax language: the module
    is type-checked and compiled to a WebAssembly text module before being
    lowered to binary. (Wax functions always carry a name, so there is no
    [name_functions] option.) *)

val output_binary :
  out_channel:out_channel ->
  ?opt_source_map_file:string ->
  binary_module ->
  unit
(** Write a binary module to [out_channel], optionally emitting a source map to
    [opt_source_map_file]. *)
