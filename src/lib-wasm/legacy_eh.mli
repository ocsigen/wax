(** Rewrite of legacy exception handling into the standard [try_table]. *)

val module_ :
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.Text.module_ ->
  Ast.location Ast.Text.module_
(** [module_ d m] rewrites each legacy [try]/[catch]/[catch_all] instruction of
    [m] into a [try_table] wrapped in a ladder of blocks, one per handler:

    {v
    block $t (type bt)              ;; the join, carrying the try's label
      block (param p) (result t_n)  ;; one block per handler, the last outermost
        ...
          block (param p) (result t_1)
            try_table (type bt) (catch tag_1 0) ... (catch_all n-1)
              body
            end
            br $t
          end
          handler_1
          br $t
        ...
      end
      handler_n                     ;; the last handler falls into the join
    end
    v}

    Each handler receives its tag's payload exactly as the legacy [catch] does,
    and a branch to the try's label, from the body or a handler, now targets the
    join, exiting the whole construct with its result. This is the shape
    [Wax_lang.Ast_utils.lower_trycatch] produces, so the decompiler recovers a
    structured [try] from it. Numeric branch depths are adjusted for the blocks
    introduced, so the rewrite also applies to a module decoded from a binary.
    The legacy [rethrow] and [delegate] are not supported by Wax, so every
    legacy [try] has an equivalent.

    The input need not have been validated: a tag or type that resolves to
    nothing is reported to [d]. A tag or type name declared in several branches
    of a conditional annotation is resolved when all its declarations agree on
    the types the rewrite needs, and reported otherwise. *)
