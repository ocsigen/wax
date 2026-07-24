val module_ :
  ?faithful:bool ->
  Wax_lang.Ast.location Wax_lang.Ast.module_ ->
  Wax_lang.Ast.location Wax_lang.Ast.module_
(** [module_ m] rewrites each function body, folding the sequential type-test
    chain that {!Ast_utils.lower_match} emits — a run of discarded blocks, each
    testing the same scrutinee with [br_on_cast_fail]/[br_on_non_null] branching
    to the block's own label, with the arm body after the test — into a
    high-level [match]. The statements after the run become the trailing default
    (sound because each arm body diverges, so they run only on the no-match
    path). A bound cast arm's separate local declaration ([let p : T;]) is
    dropped, since the recovered arm re-declares the binding on re-lowering.

    Folding is the exact inverse of {!Ast_utils.lower_match}, so a Wax [match]
    round-trips through the binary. Meant to run on {!Sink_let.module_} output,
    which places the binding declaration adjacent to its block.

    A [match] is also recovered from the {e flat} [br_on_cast_fail] chain
    hand-written GC code more often uses (one discarded block per arm). That arm
    re-lowers to the nested ladder, not the original flat chain, so it is
    semantically faithful but not byte-for-byte; [faithful] (default [false],
    the [--faithful] decompilation mode) disables it, keeping the exact-inverse
    nested-ladder fold. *)
