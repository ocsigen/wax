(** Named, groupable warnings whose reporting level is configurable.

    Each diagnostic warning has a stable {e name} (e.g. [unused-local]) and may
    belong to one or more {e groups} (e.g. [unused]). A {!policy} maps each
    warning to a {!level} — hidden, displayed, or promoted to an error — so the
    same warning can be silenced, shown, or made fatal depending on the
    invocation (see the [-W] command-line option). *)

type t =
  | Unused_local  (** A local that is declared but never read. *)
  | Unused_field
      (** A module field (a function or global) that is defined but never
          referenced, exported, or used as the start function. *)
  | Unused_import
      (** An imported function or global that is never referenced, exported, or
          used as the start function. *)
  | Unused_label  (** A block label that is declared but never branched to. *)
  | Shift_overflow
      (** A shift by a constant count at least as large as the operand's bit
          width; Wasm masks the count modulo the width, so the shift is almost
          certainly not what was meant. *)
  | Constant_trap
      (** An operation that always traps on a constant operand: an integer
          division or remainder by zero, or a trapping float-to-integer
          conversion of an out-of-range constant. *)
  | Tautological_comparison
      (** A comparison whose result is constant regardless of its variable
          operand: an unsigned comparison against zero, or a comparison of two
          identical operands. *)
  | Constant_condition
      (** A branch, loop, or [select] condition that is a constant, so it always
          (or never) takes the same path. *)
  | Unused_result
      (** The result of a side-effect-free expression is computed and then
          discarded (e.g. [_ = x + 1]). *)
  | Dead_code
      (** A statement that can never be reached because it follows an
          unconditional branch, [return], or [unreachable]. *)
  | Cast_always_fails
      (** A reference cast or test whose operand can never have the target type
          (the two are unrelated in the type hierarchy), so the cast always
          traps and the test is always false. *)
  | Eager_select
      (** A trapping or effectful operation (an integer division, a field or
          element access, a [!], a descriptor cast, a call, an assignment, …)
          appears in a branch of a [?:]. Since [?:] compiles to a [select],
          which evaluates {e both} branches, that operation runs even when the
          condition selects the other branch. *)
  | Precedence
      (** Two operators whose relative precedence is easy to misremember are
          mixed without parentheses: a shift ([<<]/[>>]) with an arithmetic
          operator ([+], [-], [*], …), or a comparison with a bitwise operator
          ([&], [|], [^]). The code is correct, but a reader (especially one
          used to C's different table) may misread the grouping. *)
  | Redundant_operation
      (** An operation with no effect on its result: an arithmetic identity
          ([x + 0], [x * 1], [x << 0], …), an absorbing operand ([x * 0],
          [x & 0]), an operation on two identical operands ([x - x], [x ^ x],
          [x & x]), a self-assignment ([x = x]), or a cast to a type the operand
          already has. *)
  | Truncated_coverage
      (** Path-sensitive validation gave up after too many conditional
          configurations. *)
  | Naming_conflict
      (** Converting from Wasm, a source name collided with another and was
          renamed to a fresh one. *)
  | Reserved_word_rename
      (** Converting from Wasm, a source name is a Wax reserved word and was
          renamed to a fresh one. *)
  | Generated_name
      (** Converting from Wasm, an unnamed but referenced parameter was given a
          generated name (it cannot be rendered anonymously). *)
  | Compound_assignment
      (** A plain assignment could use the compound form: [x = x + e] reads back
          as [x += e]. Carries a machine-applicable rewrite ([Suggestion]). *)
  | Field_punning
      (** A struct field initialised from a like-named local/global could use
          the punning shorthand: [{x: x}] reads back as [{x}] ([Suggestion]). *)
  | Redundant_annotation
      (** A [let] type annotation the inferred type already makes redundant
          could be dropped: [let x: t = e] reads back as [let x = e]
          ([Suggestion]). *)
  | Confusable_unicode
      (** A string (an export/import name, a string literal, or a data segment)
          contains a bidirectional control character that can make the source
          read differently than it runs (a "Trojan Source" character). *)

val all : t list
(** Every named warning. *)

val name : t -> string
(** The stable, hyphenated name of a warning (e.g. ["unused-local"]). *)

val description : t -> string
(** A one-line human-readable description, used in help text. *)

val is_unnecessary : t -> bool
(** Whether the warning flags code that can be removed with no change in
    behaviour (an unused binding, import, or label, or unreachable code), so an
    editor can render it faded — LSP's [DiagnosticTag.Unnecessary], VS Code's
    greyed-out dead code. *)

(** {1 Levels and policies} *)

type level =
  | Hidden  (** Suppress the warning entirely. *)
  | Displayed  (** Report it as a warning (the default). *)
  | Error  (** Promote it to an error (fails the run). *)

type policy
(** A mapping from each warning to its {!level}. *)

val default_policy : policy
(** The policy giving each warning its default level. Most warnings default to
    {!Displayed}; the From_wasm renaming warnings ([naming-conflict],
    [reserved-word-rename]), [redundant-operation], and the [suggestion] group
    ([compound-assignment], [field-punning], [redundant-annotation]) default to
    {!Hidden}. *)

val resolve : policy -> t -> level
(** [resolve policy w] is the level configured for [w]. *)

val set : policy -> string -> level -> (policy, string) result
(** [set policy name level] returns [policy] updated so that the warning named
    [name] (or every warning in the group named [name], including the special
    group ["all"]) has level [level]. Returns [Error msg] if [name] matches no
    known warning or group. Later calls override earlier ones. *)

val parse_spec : string -> (string * level, string) result
(** [parse_spec s] parses a [-W] argument of the form [NAME=LEVEL] into its
    warning/group name and level. [LEVEL] is one of [hidden], [warning], or
    [error]. Returns [Error msg] on a malformed spec or unknown level. *)

val groups : string list
(** The names of the warning groups (excluding the special ["all"]), for help
    text. *)
