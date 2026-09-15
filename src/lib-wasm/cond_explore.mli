(** Reporting for path-sensitive checking of conditional-annotation
    configurations: the configurations are enumerated by an exhaustive
    {!Cond_plan} (one run each), checked one by one into collectors, and
    {!report} folds their diagnostics into one report, each distinct diagnostic
    once, annotated with the minimal assumption under which it is reachable.

    Used by both the WAT validator and the Wax type-checker. *)

val report :
  Wax_utils.Diagnostic.context ->
  ?truncation_location:Ast.location ->
  explain:(Cond_solver.t -> string option) ->
  truncated:bool ->
  (Wax_utils.Diagnostic.entry list * Cond_solver.t) list ->
  unit
(** [report diagnostics ?truncation_location ~explain ~truncated configurations]
    reports the diagnostics of the configurations a caller checked: each
    configuration's collected diagnostics paired with its full assumption
    ({!Cond_plan.assumption}). A distinct diagnostic is reported once, with a
    "reachable when …" hint from [explain] applied to the union of the
    assumptions it arose under; a [universal] one only if that union covers the
    whole feasible space; a [truncated] exploration adds the truncation warning.
*)
