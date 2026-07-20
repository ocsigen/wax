(** The machine-applicable quick-fix suggestions the typer offers for
    hand-written Wax (redundant type annotations, compound assignment, field
    punning). Each is a [Suggestion] diagnostic carrying a source-slice-built
    {!Wax_utils.Diagnostic.edit}; the type checker calls these when
    [ctx.suggest] is set. The block/if result-type suggestions and their driver
    [context_block_typ] stay in {!Typing}, which calls {!suggest_block_result} /
    {!suggest_if_result} here. The [Suggestion]-emitting [Error] submodule is
    internal. *)

val annotation_spans :
  Typing_env.module_context ->
  Lexing.position ->
  Lexing.position ->
  (Ast.location * Ast.location) option
(** Locate the [': t'] annotation between a binding name's end and the boundary
    after it, from the source (the AST keeps no span for it). Returns the type's
    own span and the [': t'] span to delete, or [None] when it cannot be
    isolated. *)

val suggest_redundant_annotation :
  Typing_env.module_context ->
  name_end:Lexing.position ->
  boundary:Lexing.position ->
  unit
(** Suggest dropping a binding's redundant [': t'] annotation that the
    initializer's inferred type already pins. *)

val compound_assignable : Ast.binop -> bool
(** Whether a binary operator has a compound-assignment form [x op= e]. *)

val suggest_compound_assignment :
  Typing_env.module_context ->
  location:Ast.location ->
  (string, Ast.location) Ast.annotated ->
  Ast.location Ast.instr ->
  unit
(** Suggest rewriting [x = x op e] as the compound form [x op= e]. *)

val suggest_punning :
  Typing_env.module_context ->
  Ast.ident ->
  ('a Ast.instr_desc, Ast.location) Ast.annotated option ->
  unit
(** Suggest the punning shorthand [{x}] for a field written [x: x]. *)

val suggest_drop_type_name : Typing_env.module_context -> Ast.ident -> unit
(** Suggest dropping a construction's redundant [T|] type name. *)

val suggest_block_result :
  Typing_env.module_context ->
  keyword:string ->
  Lexing.position ->
  Lexing.position ->
  unit
(** Suggest dropping a block's redundant result type ([do t { … }] etc.). *)

val suggest_if_result :
  Typing_env.module_context -> Lexing.position -> Lexing.position -> unit
(** Suggest dropping an [if]-expression's redundant [=> t] result type. *)
