(** High-level conversion pipeline, reusable outside the [wax] command-line tool
    (e.g. as a preprocessor embedded in another compiler).

    Each entry point parses a source module, specializes its conditional
    annotations against [defines], and lowers it to the binary format. The same
    pipeline is implemented inline by the [wax] CLI; these functions package it
    so an embedder need not reproduce the parser instantiation and pass
    ordering. *)

type binary_module = Wax_wasm.Ast.location Wax_wasm.Ast.Binary.module_

val wax_parse_recover :
  filename:string ->
  string ->
  Wax_lang.Ast.location Wax_lang.Ast.module_ option
  * Wax_wasm.Parsing.syntax_error list
  * Wax_utils.Trivia.context
(** Parse Wax [contents] with panic-mode error recovery, returning the
    best-effort AST ([None] if recovery could not reach an accepting state), the
    list of {e all} syntax errors in source order, and the trivia context. For
    in-process consumers such as a language server; see
    {!Wax_wasm.Parsing.Make.parse_recover}. Wax resynchronizes on the statement,
    block, paren and bracket closers and on the keywords that begin a new
    top-level item or statement (see [wax_sync]). A lexer error (bad character,
    malformed byte) is recorded as a diagnostic and skipped, so parsing resumes
    past it rather than stopping. *)

val wat_parse_recover :
  filename:string ->
  string ->
  Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_ option
  * Wax_wasm.Parsing.syntax_error list
  * Wax_utils.Trivia.context
(** As {!wax_parse_recover}, for WAT. WAT is fully parenthesized, so recovery
    resynchronizes on the parentheses alone (see {!Wax_wasm.Recover}): the
    nesting-aware skip and auto-closing with [")"] salvage the constructs that
    parsed rather than dropping a whole field on the first error. *)

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
  ?source_map:bool ->
  Wax_wasm.Ast.location Wax_wasm.Ast.Binary.module_ ->
  unit
(** [output_binary ~out_channel ?source_map ast] outputs the Wasm binary AST
    [ast] to [out_channel]. A source map is additionally generated if
    [source_map] is true. *)
