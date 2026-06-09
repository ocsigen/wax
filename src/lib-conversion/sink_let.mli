val module_ :
  Wax.Ast.location Wax.Ast.module_ -> Wax.Ast.location Wax.Ast.module_
(** [module_ m] rewrites the local declarations of every function body to be
    more idiomatic. Each [let x : t;] declaration is pushed inward as far as
    possible: down to the first instruction that uses [x], and into the
    innermost block / branch that contains every use of [x]. A declaration whose
    first use is an initial assignment ([let x : t; ... x = e;], with [e] not
    mentioning [x]) is fused into [let x : t = e;].

    This is meant as a cleanup of {!From_wasm.module_} output, which emits all
    locals as bare declarations at the top of the function body. The rewrite
    preserves runtime semantics: a bare declaration generates no code, so moving
    it never reorders any computation, and fusion only relabels an assignment
    that already sat at the chosen position. *)
