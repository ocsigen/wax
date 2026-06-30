val module_ : Ast.location Ast.Text.module_ -> Ast.location Ast.Text.module_
(** [module_ m] makes every function referenced by [ref.func] inside a function
    body declared as referenceable, so the module passes strict reference
    validation. Functions already referenced in an element-segment or global
    initialiser are already declared and left alone; the rest are added to an
    existing declarative element segment (extending it) or, if there is none, a
    fresh one appended to the module.

    A module containing conditional ([(@if ...)]) fields is returned unchanged:
    a referenced function may be defined only under some configuration, so a
    single declarative segment cannot name it safely (and such a module cannot
    be emitted to the binary format anyway). *)
