(** Pure AST analysis helpers and the source-walking lint checks. The analysis
    primitives (value-effect classification, hole counting, the per-function
    collection passes) are shared with the type checker; the lint checks
    (constant conditions, shift/division/conversion traps, tautologies,
    redundant arithmetic, eager [?:], operator precedence) run once over the
    source AST and emit warnings. The warning-emitting [Error] submodule is
    internal. *)

val is_pure_unary_method : string -> bool

val is_pure_binary_method : string -> bool
(** Whether a no-/one-argument numeric instruction method ([x.abs()],
    [x.min(y)]) is pure and total. *)

val cast_is_total : Ast.casttype -> bool
(** Whether a cast never traps, so discarding its result is pointless. *)

val is_effectless : 'a Ast.instr -> bool
(** Whether evaluating an expression has no side effect and cannot trap. *)

val collect_assigned_locals :
  Typing_env.StringSet.t ->
  ('a Ast.instr_desc, 'a) Ast.annotated ->
  Typing_env.StringSet.t
(** Accumulate the local names assigned ([Set]/[Tee] targets) anywhere in an
    instruction. *)

val collect_labels : Ast.label list -> 'a Ast.instr -> Ast.label list
(** Accumulate the block labels declared anywhere in an instruction. *)

val find_eager_hazard : 'a Ast.instr -> 'a option
(** The location of a trapping/effectful operation on the eagerly-evaluated
    spine of a [?:] branch, or [None] if the branch is pure. *)

val int_literal_value : string -> int64 option
val int_literal_value_is : int64 -> 'a Ast.instr -> bool
val int_literal_value_is_zero : 'a Ast.instr -> bool

val int_operand_value : 'a Ast.instr -> int64 option
(** Constant-integer-operand parsing/matching for the lints (looking through a
    leading sign for {!int_operand_value}). *)

val lint_shift :
  Typing_env.module_context ->
  (Ast.binop, Ast.location) Ast.annotated ->
  Infer.inferred_type Infer.Cell.t ->
  'a Ast.instr ->
  unit
(** Flag a shift whose constant count is at least the operand's bit width.
    Deferred until the result cell's width is pinned. *)

val flush_deferred_lints : Typing_env.module_context -> unit
(** Run and clear the lints deferred until their result cells were pinned. *)

val lint_division :
  Typing_env.module_context ->
  (Ast.binop, Ast.location) Ast.annotated ->
  'a Ast.instr ->
  unit
(** Flag an integer [/] or [%] by a constant zero (always traps). *)

val float_literal_value : string -> float option
val round_to_f32 : float -> float
val float_operand_value : ('a Ast.instr_desc, 'a) Ast.annotated -> float option

val float_conversion_traps : [< `I32 | `I64 ] -> Ast.signage -> float -> bool
(** Constant-float-operand parsing and the trapping-conversion predicate for
    {!lint_conversion}. *)

val lint_conversion :
  Typing_env.module_context ->
  location:Ast.location ->
  Ast.casttype ->
  ('a Ast.instr_desc, 'a) Ast.annotated ->
  unit
(** Flag a strict float-to-integer conversion of a constant out of range. *)

val identical_operands : 'a Ast.instr -> 'b Ast.instr -> bool
(** Whether two operands are the same pure read (a local/global [get]). *)

val lint_comparison :
  Typing_env.module_context ->
  (Ast.binop, Ast.location) Ast.annotated ->
  (Infer.inferred_type Infer.Cell.t array * 'a) Ast.instr ->
  'b Ast.instr ->
  unit
(** Flag a comparison whose result is constant regardless of its operand. *)

val lint_redundant :
  Typing_env.module_context ->
  (Ast.binop, Ast.location) Ast.annotated ->
  (Infer.inferred_type Infer.Cell.t array * 'a) Ast.instr ->
  (Infer.inferred_type Infer.Cell.t array * 'a) Ast.instr ->
  unit
(** Flag an arithmetic operation with no effect or a constant result (off by
    default). *)

val lint_condition :
  Typing_env.module_context -> ?is_while:bool -> Ast.location Ast.instr -> unit
(** Flag a branch/loop/[select] condition that is a constant literal. *)

val lint_eager_select :
  Typing_env.module_context ->
  select:Ast.location ->
  Ast.location Ast.instr ->
  unit
(** Report an eager-evaluation hazard in a [?:] branch. *)

val binop_kind_name : [< `Arith | `Bitwise | `Comparison | `Shift ] -> string
(** Human-readable name of a binary operator's precedence class. *)

val operand_parenthesized :
  Typing_env.module_context ->
  op:('a, Ast.location) Ast.annotated ->
  side:[< `Left | `Right ] ->
  Ast.location Ast.instr ->
  bool
(** Whether a binary operator's operand was written parenthesized (from the
    source text). *)

val lint_precedence :
  Typing_env.module_context ->
  (Ast.binop, Ast.location) Ast.annotated ->
  (Ast.location Ast.instr_desc, Ast.location) Ast.annotated ->
  (Ast.location Ast.instr_desc, Ast.location) Ast.annotated ->
  unit
(** Flag a confusing precedence mix written without disambiguating parentheses.
*)

val lint_source : Typing_env.module_context -> Ast.location Ast.instr -> unit
(** Walk the source AST and report the purely-syntactic lints (constant
    conditions, eager [?:], precedence, redundant self-assignment, a pointless
    drop). The orchestrator that dispatches to the checks above. *)
