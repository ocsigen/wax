val module_ :
  Wax_lang.Ast.location Wax_lang.Ast.module_ ->
  Wax_lang.Ast.location Wax_lang.Ast.module_
(** [module_ m] rewrites each function body, folding the
    [try_table]-plus-block-ladder shape — a join block wrapping one
    parameterless block per catch clause, the [try_table] innermost with its
    value escaping to the join, and each handler's code trailing its block —
    into the structured [try { … } catch { tag => { … } … }] whose arms are
    honest fall-through code. The join label is kept as the try's label only
    when the bodies still branch to it. Ladders that do not conform (a targeted
    arm label, out-of-order clauses, a mid-list catch-all, …) are left as-is,
    decompiling to the bracket form instead.

    Folding is the exact inverse of {!Ast_utils.lower_trycatch}, so re-lowering
    reproduces the original blocks and the rewrite preserves runtime semantics.
    Meant to run on {!From_wasm.module_} output before {!Sink_let.module_}
    (which would otherwise sink locals into the ladder blocks and hide the
    shape). *)
