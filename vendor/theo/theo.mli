(** Theory-Augmented Binary Decision Diagrams (BDDs)

    This module provides an efficient implementation of Binary Decision Diagrams
    with support for theory reasoning over linear orders and equality (including
    booleans, strings, integers, semantic versions).

    BDDs are canonical representations of boolean functions that enable
    efficient logical operations and satisfiability checking through
    hash-consing and memoization.

    {b Features:}
    - Automatic node sharing via hash-consing
    - Memoized operations for performance
    - Theory atoms: boolean tests, string equality, version comparisons
    - Type-safe variable system using GADTs

    {b Example usage:}
    {[
      module Theo = Theo.Make(Theo.Void)
      let open Theo.Syntax in
      let b1 = Theo.var Boolean in
      let b2 = Theo.var Boolean in
      let expr = Theo.atom b1 && not (Theo.atom b2) in
      if Theo.is_tautology expr then Printf.printf "Always true\n"
      else Printf.printf "Depends on variables\n"
    ]}

    {b Architecture:} The library is built around a few core concepts:
    - [Make]: The core BDD engine. It takes a [Theory] as input and produces a
      BDD module.
    - [Theory]: An interface for values that can be part of the BDD (e.g.,
      integers, strings).
    - [Combine]: A functor to combine two theories into one (sum type).
    - [Primitive_theory]: Standard theories like [Leq] (linear order) and [Eq]
      (equality).

    {b Example: Combining Theories} To use multiple theories (e.g., String
    equality and Version comparisons) in the same BDD:

    {[
      (* 1. Define your atomic types *)
      module StringAtom = struct ... end (* implements Comparable *)
      module VersionAtom = struct ... end (* implements Comparable *)

      (* 2. Instantiate primitive theories *)
      module StringEq = Theo.Eq(StringAtom)
      module VersionLeq = Theo.Leq(VersionAtom)

      (* 3. Combine them into a single theory *)
      module MyTheory = Theo.Combine(VersionLeq)(StringEq)

      (* 4. Create the BDD module *)
      module MyBDD = Theo.Make(MyTheory)

      (* 5. Instantiate syntax helpers for convenient construction *)
      (* Notice we pass parts of the sum theory to the helpers *)
      module V = VersionLeq.Syntax(MyTheory.Left(MyBDD))
      module S = StringEq.Syntax(MyTheory.Right(MyBDD))

      (* 6. Now you can mix them! *)
      let v_var = MyBDD.var ()
      let s_var = MyBDD.var ()
      let expr = MyBDD.and_ V.(v_var < v) S.(s_var = s)
    ]}

    {b Example: Working with Constraints} You can also use the syntax modules to
    build [restrict] constraints, and pattern match on constraints using
    [view_constraint].

    {[
      (* 1. Build constraint syntax helpers *)
      (* Instead of MyBDD, we pass MyBDD.Constraint to the syntax functors *)
      module V_cstr = VersionLeq.Syntax (MyTheory.Left (MyBDD.Constraint))
      module S_cstr = StringEq.Syntax (MyTheory.Right (MyBDD.Constraint))

      (* 2. Create constraints *)
      (* Note: These return atomic_constraint list, NOT a BDD *)
      let c1 = V_cstr.(v_var < v)
      let c2 = S_cstr.(s_var = s)

      (* 3. Combine constraints *)
      let constraints = MyBDD.Constraint.and_ c1 c2

      (* 4. Restrict a BDD *)
      let restricted_expr = MyBDD.restrict expr constraints

      (* 5. Introspection (Pattern Matching) *)
      let match_constraint (c : MyBDD.atomic_constraint) =
        match MyBDD.view_constraint c with
        | MyBDD.Constraint { var; payload = Bool; value } ->
            Printf.printf "Bool var %d = %b" var value
        | MyBDD.Constraint { var; payload = Theory desc; value } -> (
            (* 'desc' is a 'desc MyTheory.t' (the sum type) *)
            match desc with
            | MyTheory.Left (VersionLeq.Bound { limit; inclusive }) ->
                Printf.printf "Version <= %s is %b"
                  (VersionAtom.to_string limit)
                  value
            | MyTheory.Right (StringEq.Const s) ->
                Printf.printf "String = %s is %b" (StringAtom.to_string s) value
            )
    ]} *)

(**/**)

type _ category

(**/**)

(** The interface for theory atoms.

    A theory [T] defines the type of atomic formulas (atoms) that can appear in
    the BDD nodes. For example, in a theory of semantic versions, [T.t] might
    represent constraints like "v < 1.0.0".

    The operations [equal], [compare], and [hash] are crucial for the BDD's
    internal hash-consing mechanism, ensuring that equivalent formulas are
    physically shared. *)
module type Theory = sig
  type _ t
  (** The type of theory atoms. The type parameter is a phantom type used to
      distinguish different kinds of atoms (e.g., boolean vs integer) if needed,
      or ignored if the theory is uniform. *)

  val equal : _ t -> _ t -> bool
  (** Equality check for atoms. Must be consistent with [compare] and [hash]. *)

  val compare : _ t -> _ t -> int
  (** Total ordering function. Used for set/map operations and canonical
      ordering in BDDs. *)

  val hash : _ t -> int
  (** Hash function for atoms. Must be compatible with [equal]. *)

  val to_string : _ t -> string
  (** String representation for debugging. *)
end

(** {1 Variables} *)

(** Global unique variables. *)
module Var : sig
  type 'kind t
  (** The type of variables. The type parameter indicates the kind of value
      (bool, string, etc.). *)

  val fresh : unit -> 'kind t
  (** Create a fresh variable with a globally unique identifier. *)

  val equal : 'kind t -> 'kind t -> bool
  val compare : 'kind t -> 'kind t -> int
  val hash : 'kind t -> int
end

(** {1 The Core BDD Engine} *)

(** Functor to create a BDD implementation for a specific theory.

    [Make(T)] produces a module containing all BDD operations (logical
    connectives, quantifiers, etc.) specialized for the theory [T].
    - Use [Make(Void)] for standard boolean BDDs.
    - Use [Make(Combine(A)(B))] for multi-theory BDDs. *)
module Make (T : Theory) : sig
  (** {1 Types} *)

  type t
  (** Abstract type representing a BDD expression. *)

  (** {1 Standard Interface} *)

  val equal : t -> t -> bool
  (** [equal a b] checks if [a] and [b] are physically equal. Since hash-consing
      guarantees unique representation, this is equivalent to logical equality.
      Same as [equivalent].

      Complexity: O(1) *)

  val compare : t -> t -> int
  (** [compare a b] compares the unique identifiers of [a] and [b]. defines a
      total ordering suitable for [Set] and [Map].

      Complexity: O(1) *)

  val hash : t -> int
  (** [hash a] returns the unique identifier of [a]. Suitable for [Hashtbl].

      Complexity: O(1) *)

  val size : t -> int
  (** [size expr] returns the number of unique nodes in the BDD. Useful for
      analyzing BDD complexity.

      Complexity: O(|expr|) *)

  (** {1 Atomic Boolean Formulas} *)

  val bool : 'kind Var.t -> t
  (** [bool v] creates an expression that is true when boolean variable [v] is
      true. *)

  (** {1 Logical Constants} *)

  val true_ : t
  (** The constant true expression. *)

  val false_ : t
  (** The constant false expression. *)

  (** {1 Logical Connectives} *)

  val not : t -> t
  (** [not expr] negates the expression.

      Complexity: O(1) *)

  val and_ : t -> t -> t
  (** [and_ a b] computes the conjunction (AND) of two expressions.

      Complexity: O(|a| × |b|) where |·| is the number of nodes *)

  val or_ : t -> t -> t
  (** [or_ a b] computes the disjunction (OR) of two expressions.

      Complexity: O(|a| × |b|) *)

  val xor : t -> t -> t
  (** [xor a b] computes the exclusive or of two expressions. True when exactly
      one of [a] or [b] is true.

      Complexity: O(|a| × |b|) *)

  val iff : t -> t -> t
  (** [iff a b] computes the biconditional (if and only if) of two expressions.
      True when [a] and [b] have the same truth value. Equivalent to
      [not (xor a b)].

      Complexity: O(|a| × |b|) *)

  val implies : t -> t -> t
  (** [implies a b] constructs the implication [a => b] (equivalent to
      [not a || b]). Returns a BDD representing the logical implication.

      To check if [a] logically implies [b] (i.e., is a tautology), use
      [is_tautology (implies a b)].

      Complexity: O(|a| × |b|) *)

  val ite : t -> t -> t -> t
  (** [ite cond then_ else_] computes the If-Then-Else operation. Equivalent to
      [(cond && then_) || (not cond && else_)].

      Complexity: O(|cond| × |then_| × |else_|) *)

  (** Syntax for convenient infix operators. Open locally with
      [let open Theo.Syntax in ...] *)
  module Syntax : sig
    val bool : bool Var.t -> t
    val ( && ) : t -> t -> t
    val ( || ) : t -> t -> t
    val not : t -> t

    val ( ==> ) : t -> t -> t
    (** Implication *)

    val ( <=> ) : t -> t -> t
    (** Biconditional (iff) *)

    val ( <+> ) : t -> t -> t
    (** Exclusive OR (xor) *)
  end

  (** {1 Properties} *)

  val is_tautology : t -> bool
  (** [is_tautology expr] returns true if [expr] is the constant true.

      Complexity: O(1) *)

  val is_satisfiable : t -> bool
  (** [is_satisfiable expr] returns true if [expr] has at least one satisfying
      assignment. Equivalent to [sat expr <> None] but more efficient.

      Complexity: O(1) *)

  val equivalent : t -> t -> bool
  (** [equivalent a b] checks if [a] and [b] are structurally identical. Due to
      hash-consing, structurally identical BDDs represent the same logical
      function.

      Complexity: O(1) *)

  val logical_implies : t -> t -> bool
  (** [logical_implies a b] checks if [a] logically implies [b] (i.e., [a => b]
      is valid/tautology) without fully constructing the result. *)

  val is_disjoint : t -> t -> bool
  (** [is_disjoint a b] checks if [a] and [b] are disjoint (i.e., [a /\ b] is
      unsatisfiable) without fully constructing the result. *)

  val is_exhaustive : t -> t -> bool
  (** [is_exhaustive a b] checks if [a] and [b] cover the entire space (i.e.,
      [a \/ b] is a tautology) without fully constructing the result. *)

  (** {1 Constraints} *)

  type atomic_constraint
  (** Represents an atomic constraint on a variable that contributes to
      satisfying the formula. *)

  (** Pattern-matchable view of the atomic constraint *)
  type constraint_view =
    | Constraint : {
        var : 'kind Var.t;  (** The variable involved in the constraint. *)
        payload : 'kind payload;
            (** The nature of the constraint: [Bool] for boolean variables, or
                [Theory desc] for theory atoms. *)
        value : bool;
            (** The truth value asserted for this constraint.
                - If [value] is [true], the constraint is [var] (or [atom]).
                - If [value] is [false], the constraint is [not var] (or
                  [not atom]). *)
      }
        -> constraint_view

  (** The payload of an atomic constraint. *)
  and 'kind payload =
    | Bool : bool payload
    | Theory : 'kind desc -> 'kind payload

  and 'kind desc = 'kind T.t

  val view_constraint : atomic_constraint -> constraint_view
  (** [view_constraint c] returns a pattern-matchable view of the atomic
      constraint [c]. *)

  module Constraint : sig
    type t = atomic_constraint list

    val bool : 'kind Var.t -> bool -> t
    (** [bool v b] creates a constraint asserting that boolean variable [v] has
        value [b]. *)

    val not : t -> t
    (** [not c] negates the constraint [c]. Supports only single atomic
        constraints.
        @raise Invalid_argument if [c] is not a single atomic constraint. *)

    val and_ : t -> t -> t
    (** [and_ c1 c2] combines two constraints with logical AND. *)

    val or_ : t -> t -> t
    (** [or_ c1 c2] combines two constraints with logical OR.
        @raise Invalid_argument
          always. Disjunctions cannot be represented as a simple list of atomic
          constraints. Use full BDDs for disjunctions. *)

    (**/**)

    type nonrec 'kind desc = 'kind desc

    val atom : 'kind Var.t -> 'kind category -> 'kind desc -> t
    (** Low-level function to build atom formulas *)
  end

  (** {1 Operations} *)

  val restrict : t -> atomic_constraint list -> t
  (** [restrict expr constraints] simplifies [expr] by assuming the specified
      constraints hold.

      Complexity: O(|expr|) *)

  type constant_result = Constant of bool | NonConstant

  val ite_constant : t -> t -> t -> constant_result
  (** [ite_constant f g h] evaluates if the result of [ite f g h] is a constant
      boolean without fully constructing the BDD. Returns [Constant b] if the
      result corresponds to [b], or [NonConstant] otherwise. *)

  (** {1 Quantifiers} *)

  val exists : _ Var.t -> t -> t
  (** [exists v expr] eliminates variable [v] from [expr] by computing the
      disjunction over all possible values. For a boolean variable, this is
      equivalent to
      [restrict expr [Boolean(v, true)] || restrict expr [Boolean(v, false)]].
      For theory variables, it quantifies over all atoms mentioning [v].

      Example:
      [let expr' = exists b (and_ (atom b) (atom c)) (* Result: atom c *)]

      Complexity: O(|expr|²) *)

  val forall : _ Var.t -> t -> t
  (** [forall v expr] eliminates variable [v] from [expr] by computing the
      conjunction over all possible values. For a boolean variable, this is
      equivalent to
      [restrict expr [Boolean(v, true)] && restrict expr [Boolean(v, false)]].

      Example:
      [let expr' = forall b (or_ (atom b) (atom c)) (* Result: atom c *)]

      Complexity: O(|expr|²) *)

  (** {1 Solving} *)

  val sat : t -> atomic_constraint list option
  (** [sat expr] finds a satisfying set of constraints for [expr], if one
      exists. Returns [Some constraints] where [constraints] is a list of atomic
      constraints that make the expression true. Returns [None] if the
      expression is unsatisfiable (equivalent to [false_]). *)

  val shortest_sat : t -> atomic_constraint list option
  (** [shortest_sat expr] finds a satisfying set of constraints with the minimum
      number of atomic constraints (shortest path in the BDD DAG). Returns
      [None] if unsatisfiable. *)

  (** {1 Batch Operations} *)

  val and_list : t list -> t
  (** [and_list exprs] computes the conjunction of all expressions in [exprs].
      Returns [true_] for an empty list. Uses a divide-and-conquer strategy to
      minimize intermediate BDD sizes and maximize cache reuse.

      Example: [let expr = and_list [e1; e2; e3]]

      Complexity: In the worst case, combining N BDDs of size S can result in
      exponential growth O(S^N). However, for many practical constraint
      problems, the divide-and-conquer approach yields typically O(S log N)
      performance. *)

  val or_list : t list -> t
  (** [or_list exprs] computes the disjunction of all expressions in [exprs].
      Returns [false_] for an empty list.

      Example: [let expr = or_list [e1; e2; e3]]

      Complexity: Worst case O(S^N), typically O(S log N). *)

  (** {1 Debugging} *)

  val to_string : t -> string
  (** [to_string expr] returns a human-readable representation of the BDD
      structure. Shows the decision tree with atoms and branches. *)

  val print_dot : out_channel -> t -> unit
  (** [print_dot chan expr] prints the BDD in Graphviz DOT format to the given
      channel. *)

  val print_stats : unit -> unit
  (** [print_stats ()] prints statistics for all internal caches (atom table,
      node table, operation caches) to stdout. Useful for debugging and
      performance analysis. *)

  (**/**)

  val atom : 'kind Var.t -> 'kind category -> 'kind desc -> t
  (** Low-level function to build atom formulas *)
end

(** The abstract interface for "formulas". This abstraction allows syntax
    helpers (like [Leq.Syntax]) to be reused with any BDD implementation that
    contains the appropriate theory. *)
module type Formula = sig
  type t

  val not : t -> t
  val and_ : t -> t -> t
  val or_ : t -> t -> t

  (**/**)

  type _ desc

  val atom : 'kind Var.t -> 'kind category -> 'kind desc -> t
  (** Low-level function to build atom formulas *)
end

(** {1 Theory Composition} *)

(** [Combine(A)(B)] creates a new theory that is the sum of [A] and [B]. This
    allows a single BDD to reason about multiple types of atoms simultaneously.

    The resulting module provides [Left] and [Right] functors to lift a
    [Formula] operating on the combined theory back to a [Formula] operating on
    just [A] or [B]. This is the key mechanism that allows syntax modules to be
    specific to a theory but compatible with the combined BDD. *)
module Combine (A : Theory) (B : Theory) : sig
  (** The sum type of theory atoms.

      This type is crucial for introspection (via [view_constraint]). Pattern
      match on [Left] or [Right] to determine which specific theory an atom
      belongs to. *)
  type _ t = Left : 'a A.t -> 'a t | Right : 'a B.t -> 'a t

  include Theory with type 'kind t := 'kind t

  (** Lifts a Formula from the combined theory back to theory [A].

      This functor allows you to use syntax helpers defined for theory [A] (like
      [VersionLeq.Syntax]) within the context of the combined BDD. *)
  module Left (F : Formula with type 'kind desc = 'kind t) :
    Formula with type 'kind desc = 'kind A.t and type t = F.t

  (** Lifts a Formula from the combined theory back to theory [B].

      This functor allows you to use syntax helpers defined for theory [B] (like
      [StringEq.Syntax]) within the context of the combined BDD. *)
  module Right (F : Formula with type 'kind desc = 'kind t) :
    Formula with type 'kind desc = 'kind B.t and type t = F.t
end

module Void : Theory
(** An empty theory.

    Used when no theory reasoning is required. BDDs created with
    [Theo.Make(Void)] behave like standard BDDs, supporting only boolean
    variables. *)

(** {1 Primitive theories} *)

(** Input signature for primitive theories.

    Modules satisfying this interface can be lifted into BDD theories (like
    [Leq] or [Eq]). Users must provide standard comparison and hashing
    operations for their atomic types. *)
module type Comparable = sig
  type t
  (** The type of values in the theory (e.g., [string], [int], [Version.t]). *)

  val equal : t -> t -> bool
  (** Equality check. *)

  val compare : t -> t -> int
  (** Total ordering. Returns negative if first < second, 0 if equal, positive
      if first > second. *)

  val hash : t -> int
  (** Hash function. Must be compatible with [equal]. *)

  val to_string : t -> string
  (** String representation for debugging and visualization. *)
end

(** Augmented theory interface for primitive theories.

    This interface defines a specific [kind] phantom type that uniquely
    identifies the theory domain. This uses OCaml's type system to ensure that
    variables from different theories cannot be mixed or confused. *)
module type Primitive_theory = sig
  include Theory

  type elt
  type kind

  (**/**)

  val category : kind category
  (* The [category] is used by the BDD engine to group atoms and
     implement / optimize operations differently depending on the
     theory (e.g. specialized implications for linear orders). *)
end

(** The theory of linear order (<=, <, =, <>). *)
module Leq (C : Comparable) : sig
  type kind
  type _ t = Bound : { limit : C.t; inclusive : bool } -> kind t

  include
    Primitive_theory
      with type kind := kind
       and type 'kind t := 'kind t
       and type elt = C.t

  module Syntax (F : Formula with type 'kind desc = 'kind t) : sig
    val lt : kind Var.t -> elt -> F.t
    val le : kind Var.t -> elt -> F.t
    val ( <= ) : kind Var.t -> elt -> F.t
    val ( < ) : kind Var.t -> elt -> F.t
    val ( >= ) : kind Var.t -> elt -> F.t
    val ( > ) : kind Var.t -> elt -> F.t
    val ( = ) : kind Var.t -> elt -> F.t

    val ( <> ) : kind Var.t -> elt -> F.t
    (** [v <> x] is equivalent to [v < x || v > x].
        @raise Invalid_argument
          if [F] is a [Constraint] module, as disjunctions are not supported in
          constraints. *)
  end
end

(** The theory of equality (=, <>). *)
module Eq (C : Comparable) : sig
  type kind
  type _ t = Const : C.t -> kind t

  include
    Primitive_theory
      with type kind := kind
       and type 'kind t := 'kind t
       and type elt = C.t

  module Syntax (F : Formula with type 'kind desc = 'kind t) : sig
    val eq : kind Var.t -> elt -> F.t
    val ( = ) : kind Var.t -> elt -> F.t
    val ( <> ) : kind Var.t -> elt -> F.t
  end
end
