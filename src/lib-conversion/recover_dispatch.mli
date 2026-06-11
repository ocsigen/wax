val module_ :
  Wax.Ast.location Wax.Ast.module_ -> Wax.Ast.location Wax.Ast.module_
(** [module_ m] rewrites each function body, folding the conventional
    dense-switch shape — a stack of void blocks with a [br_table] in the
    innermost and a case body after each block — into a high-level [dispatch]
    with every case an arm. The outermost case's body is the code following the
    outermost block, so a block is folded together with the statements after it.
    This recovers the jump-table idiom when decompiling WAT/WASM to Wax (and
    lets a Wax [dispatch] survive a round trip through the binary).

    Folding is the exact inverse of {!Ast_utils.lower_dispatch}, so re-lowering
    reproduces the original blocks byte-for-byte and the rewrite always
    preserves runtime semantics. Meant to run on {!From_wasm.module_} output,
    before {!Sink_let.module_} (which would otherwise sink locals into the case
    blocks and hide the shape). *)
