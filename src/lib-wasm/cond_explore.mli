(** Path-sensitive exploration of conditional-annotation configurations.

    Shared driver for checking code that contains conditional annotations: it
    explores every reachable configuration (a choice of branch at each
    conditional), runs a caller-provided [check] on each specialized
    (conditional-free) configuration, and reports each distinct diagnostic once,
    annotated with the minimal assumption under which it is reachable.

    Used by both the WAT validator and the Wax type-checker. *)

val check_all :
  Wax_utils.Diagnostic.context ->
  ?truncation_location:Ast.location ->
  ?explain:(Cond_solver.env -> Cond_solver.t -> string option) ->
  specialize:
    (Cond_solver.env ->
    Cond_solver.t ->
    enqueue:(Cond_solver.t -> unit) ->
    record:(Cond_solver.t -> unit) ->
    'cfg) ->
  check:(Wax_utils.Diagnostic.context -> 'cfg -> unit) ->
  unit ->
  unit
(** [check_all diagnostics ?truncation_location ~specialize ~check ()]:

    - seeds a worklist with the assumption [Cond_solver.true_];
    - for each assumption (deduplicated by BDD identity, skipping unsatisfiable
      ones): calls [specialize env asm ~enqueue ~record] to produce a
      conditional-free configuration, interning condition variables in the fresh
      per-call [env]. [specialize] resolves each conditional against [asm]; for
      an undetermined conditional it selects one branch, [enqueue]s the
      assumption for the other, and [record]s the chosen branch's literal (so
      the configuration's full assumption can be accumulated);
    - runs [check cctx cfg] into a buffering [cctx];
    - discards the configuration's diagnostics if its accumulated assumption is
      unsatisfiable (an optimistically-explored, infeasible combination);
    - otherwise folds them into a table keyed by (location, message), OR-ing the
      reachability assumptions;
    - finally reports each distinct diagnostic once to [diagnostics] with a
      "reachable when …" hint derived from [explain] (default
      {!Cond_solver.explain}; pass a style-specific renderer to match the source
      syntax).

    If exploration exceeds an internal configuration cap, a truncation warning
    is emitted at [truncation_location] (when provided). *)
