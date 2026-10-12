(** Rewrite of the legacy [try_legacy] into the structured [try]. *)

val module_ :
  Wax_utils.Diagnostic.context ->
  typed:Typing.typed_module_annotation Ast.module_ ->
  Ast.location Ast.module_ ->
  Ast.location Ast.module_
(** [module_ d ~typed m] rewrites each [try_legacy] of [m] into the structured
    [try { … } catch { … }], which lowers to the standard [try_table]. The two
    differ only in where a handler's completion goes: a legacy handler exits the
    whole construct, a structured arm falls into the next arm. So every arm but
    the last gets a trailing [br] to the try's label carrying the try's result
    (one [_] hole per value: [typed], the result of type-checking [m], tells how
    many values an unannotated try yields), unless it already ends by diverging.
    A try that needs such a branch and has no label gets a fresh one, distinct
    from every label of its function so that no branch is captured by it. *)
