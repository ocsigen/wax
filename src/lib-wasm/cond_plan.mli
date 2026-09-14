(** The configuration plan behind a stitched preserved tree.

    A module with conditional annotations is typed once per {e run}, each run a
    configuration that exists (a consistent choice of branch at every
    conditional it reaches), and the typed branches are stitched back into the
    preserved tree: every branch is kept from the one run that {e owns} it. The
    plan fixes, ahead of typing, which runs there are and which branch each run
    selects at each conditional, so the typer, the lowering and the Wasm→Wax
    converter's stack model all consult the same decisions instead of each
    re-deriving them.

    The runs are built greedily: the primary run starts from no assumption and,
    at each conditional in stream order (the field-level conditionals first,
    then the bodies by rank), selects the then-branch whenever its condition is
    consistent with the assumptions accumulated so far, refining the assumption
    either way. Each unselected branch that no run owns yet gets a run of its
    own, seeded with the assumption in force at that point conjoined with the
    branch's literal, so the world it is typed in is the one the enclosing
    decisions describe. A branch no consistent world reaches (its condition
    contradicts the enclosing ones) still needs a typed form for the preserved
    tree: it is typed in a {e forced} run that replays its enclosing branch's
    owner decision for decision and selects it anyway; inside such a dead branch
    every nested conditional takes its else-branch.

    A conditional is identified by its own source span. *)

type item =
  | Cond of {
      key : Ast.location;  (** the conditional's own span: its identity *)
      cond : Ast.cond;
      then_ : item list;
          (** the conditionals nested in the then-branch, in decision order *)
      else_ : item list option;
          (** as [then_] for the else-branch; [None] when there is none *)
    }
  | Body of { rank : int; items : item list }
      (** A function body or initializer: its conditionals are decided in the
          body phase, after every field-level conditional, bodies ordered by
          [rank] then by position (the typer types global initializers before
          function bodies). A body holding no conditional need not appear. *)

type t
type run = int

val make : Wax_utils.Diagnostic.context -> item list -> t
(** Build the plan for a module whose conditionals have the given shape: the
    field-level conditionals in order, each holding its nested conditionals and
    bodies. Ill-formed conditions are reported to the diagnostic context (see
    {!Cond_solver.of_cond}). A shape without conditionals yields the single
    primary run. *)

val runs : t -> run list
(** Every run, the primary first. *)

val primary : t -> run

val select : t -> run -> Ast.location -> bool
(** The branch [run] selects at the conditional with that span: [true] for the
    then-branch. Raises if the run never reaches that conditional. *)

val owner : t -> Ast.location -> bool -> run option
(** The run whose typing of that branch the stitched tree keeps, or [None] when
    the branch is not in the plan (a conditional with no else-branch has no else
    side). *)

val select_owned : t -> Ast.location -> bool
(** The decision at that conditional in the run that owns the branch enclosing
    it (the primary run at the top level): the world the preserved tree's copy
    of the conditional is typed in. *)
