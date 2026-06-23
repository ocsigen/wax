(** Specialization of conditional annotations against user-supplied variable
    bindings (the [-D]/[--define] CLI option).

    Conditional annotations [(@if <cond> ...)] are normally preserved verbatim
    (see {!Cond_solver} for their path-sensitive validation). Given values for
    some condition variables, this module partially evaluates the conditions:

    - a conditional whose condition becomes fully determined is removed,
      splicing the surviving branch into the enclosing position;
    - a conditional that still mentions unset variables is kept, with its
      condition simplified (the known variables substituted and the result
      constant-folded). *)

type value = Bool of bool | Version of int * int * int | String of string

type bindings
(** A mapping from condition-variable names to values. *)

val parse_define : string -> (string * value, string) result
(** [parse_define s] parses one [-D]/[--define] argument, either ["name"] or
    ["name=value"]. A bare name binds a boolean [true]. Otherwise the value kind
    is inferred: ["true"]/["false"] is a boolean, [N.N.N] (three non-negative
    integers) a version, and anything else a string. Returns [Error msg] on a
    malformed argument (an empty variable name). *)

val of_list : (string * value) list -> bindings
(** Build bindings from name/value pairs. On a duplicate name, the last entry
    wins. *)

val is_empty : bindings -> bool

type result =
  | True
  | False
  | Residual of Ast.cond
      (** The outcome of partially evaluating a condition: a determined
          constant, or a residual condition still mentioning unset variables. *)

val eval : Wax_utils.Diagnostic.context -> bindings -> Ast.cond -> result
(** [eval ctx env c] partially evaluates [c] under [env]. Unbound variables are
    left in the residual; bound ones are substituted and the condition is
    constant-folded. Reports an error diagnostic (and leaves the offending
    sub-condition residual) when a variable is set to a value of a kind
    incompatible with how the condition uses it. *)

val module_ :
  Wax_utils.Diagnostic.context ->
  bindings ->
  Ast.location Ast.Text.module_ ->
  Ast.location Ast.Text.module_ * (int * int) list
(** Splice out and simplify every conditional annotation in a WAT module
    according to [eval]. Returns the specialized module and the half-open byte
    ranges of the branches that were removed, for dropping their comments (see
    {!Wax_utils.Trivia.drop_in_ranges}). With empty [bindings] this is the
    identity (no conditional is determined, so all are kept unchanged) and no
    range is produced. *)
