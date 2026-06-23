val module_ :
  Wax_lang.Ast.location Wax_lang.Ast.module_ ->
  Wax_lang.Ast.location Wax_lang.Ast.module_
(** [module_ m] rewrites each function body, folding the [loop] shape that
    {!Ast_utils.lower_while} produces — a void [loop] whose body is a single
    back-edged [if] (leading test) — into a high-level [while] loop. The
    (possibly synthetic) loop label is kept only when the body still branches to
    it once the back-edge is removed (a "continue"), so a label-less source loop
    round-trips label-less. A trailing-test [loop] (ending in a back-edged
    [br_if]) has no leading-[while] equivalent and is left a bare [loop].

    Folding is the exact inverse of the lowering, so re-lowering reproduces the
    original [loop] byte-for-byte and the rewrite always preserves runtime
    semantics. Meant to run on {!From_wasm.module_} output, after
    {!Recover_dispatch.module_} and before {!Sink_let.module_} (which would
    otherwise sink locals into the loop body and hide the shape). *)
