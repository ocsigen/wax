An instruction method or field access on a hole '_' whose type is still
unconstrained (e.g. in dead code after 'unreachable') keeps the call rather
than collapsing it, so hole counting stays consistent and type-checking does
not crash:

  $ wax check method.wax

  $ wax check field.wax
