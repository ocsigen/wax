(** BDD-based reasoning over conditional-annotation conditions, used for
    path-sensitive validation.

    Conditions [(@if <cond> ...)] are translated into boolean formulas (BDDs)
    over condition variables. Boolean variables, version comparisons and string
    equalities are modeled precisely (using the vendored {!Theo} library);
    conditions that cannot be modeled are reported as diagnostics. *)

type t
(** A boolean formula over condition variables. *)

val true_ : t
val false_ : t
val and_ : t -> t -> t
val or_ : t -> t -> t
val not_ : t -> t

val is_satisfiable : t -> bool
(** Whether the formula has a satisfying assignment (theory-aware: e.g.
    contradictory version bounds are unsatisfiable). *)

val logical_implies : t -> t -> bool
(** [logical_implies a b] is true when [a] entails [b]. *)

val equal : t -> t -> bool
val hash : t -> int

val of_cond : Utils.Diagnostic.context -> location:Ast.location -> Ast.cond -> t
(** [of_cond ctx ~location c] translates condition [c] into a formula. A
    diagnostic is reported (once per source location) for conditions that cannot
    be modeled; such conditions become a fresh unconstrained variable so that
    exploration can proceed. [location] is the enclosing conditional, used when
    a sub-condition carries no location of its own. *)

val explain : t -> string option
(** [explain f] returns a minimal human-readable assumption that makes [f]
    satisfiable (via [shortest_sat]), e.g. ["$oxcaml and not $debug"]. Returns
    [None] when [f] is a tautology (always reachable) or unsatisfiable. *)
