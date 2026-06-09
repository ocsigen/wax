(** Specialization of Wax conditional annotations ([#[if(...)]] / [#[else]])
    against user-supplied variable bindings, the Wax-AST counterpart of
    {!Wasm.Cond_specialize.module_}. *)

val module_ :
  Utils.Diagnostic.context ->
  Wasm.Cond_specialize.bindings ->
  Ast.location Ast.module_ ->
  Ast.location Ast.module_ * (int * int) list
(** Splice out and simplify every conditional annotation in a Wax module,
    according to {!Wasm.Cond_specialize.eval}. Returns the specialized module
    and the half-open byte ranges of the branches that were removed, for
    dropping their comments (see {!Utils.Trivia.drop_in_ranges}). With empty
    bindings this is the identity and no range is produced. *)
