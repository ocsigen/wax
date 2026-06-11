val module_ :
  Wax.Ast.location Wax.Ast.module_ -> Wax.Ast.location Wax.Ast.module_
(** [module_ m] rewrites each function body, folding the [loop] shapes that
    {!Ast_utils.lower_while} / {!Ast_utils.lower_dowhile} produce — a void
    [loop] whose body is a single back-edged [if] (leading test) or whose last
    instruction is a back-edged [br_if] (trailing test) — into a high-level
    [while] / [do]-[while] loop. The (possibly synthetic) loop label is kept
    only when the body still branches to it once the back-edge is removed (a
    "continue"), so a label-less source loop round-trips label-less.

    Folding is the exact inverse of the lowering, so re-lowering reproduces the
    original [loop] byte-for-byte and the rewrite always preserves runtime
    semantics. Meant to run on {!From_wasm.module_} output, after
    {!Recover_dispatch.module_} and before {!Sink_let.module_} (which would
    otherwise sink locals into the loop body and hide the shape). *)
