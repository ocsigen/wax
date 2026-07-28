(** Optional compiler hints carried by an instruction.

    The branch-hinting and compilation-hints proposals both attach advisory
    metadata to an instruction through a [metadata.code.*] custom section keyed
    by the instruction's byte offset from the start of the function body. The
    hints have no effect on behaviour: an engine is free to ignore them, and
    dropping one changes only performance, never semantics.

    Hints live in a field of the instruction record rather than in a wrapper
    node, so that the pervasive matches on an instruction's [desc] neither see
    them nor have to see through them. The cost is that a pass which rebuilds an
    instruction from scratch (instead of with [{ i with desc = ... }]) drops its
    hints — a lost hint, never a mistyped program.

    A hint belongs on the operation itself, never on a [Folded] wrapper around
    it: the branch opcode is emitted only after the folded operands, so that is
    where the encoder takes the offset and where the decoder puts it back.

    ['idx] is how the enclosing AST spells a function reference: an index or a
    name in the Wasm ASTs, an identifier in Wax. *)

type 'a hint = { value : 'a; loc : Wax_utils.Ast.location }
(** A hint value together with the span of the annotation or attribute it was
    written as, so that a diagnostic about a misplaced or malformed hint is
    blamed at the hint rather than at the instruction it decorates. A hint
    recovered from a binary was never written down and takes the instruction's
    own span. *)

type freq = int
(** The wire byte of a [metadata.code.instr_freq] hint: an offset base-2
    logarithm of the instruction's expected executions per call of its function,
    so [32] means once. [0] means "never optimize" and [127] "always optimize";
    the proposal's formula otherwise clamps to \[1, 64\]. Kept as the raw byte
    so that a value a hand-written binary put outside that range still
    round-trips. *)

type 'idx t = {
  branch : bool hint option;
      (** [metadata.code.branch_hint]: [Some true] = likely taken. *)
  freq : freq hint option;  (** [metadata.code.instr_freq]. *)
  targets : ('idx * int) list hint option;
      (** [metadata.code.call_targets]: the likely targets of an indirect call
          with each one's frequency as a percentage. The percentages must sum to
          at most 100; a shortfall says other, unlisted targets take the
          remainder. *)
}

val none : 'idx t
(** No hints at all — what an instruction carries unless something says
    otherwise. *)

val is_empty : 'idx t -> bool
(** Whether [t] carries no hint, and so needs nothing emitted for it. *)

val branch : Wax_utils.Ast.location -> bool -> 'idx t -> 'idx t
(** [branch loc likely t] sets [t]'s branch hint, written at [loc]. *)

val freq : Wax_utils.Ast.location -> freq -> 'idx t -> 'idx t
(** [freq loc f t] sets [t]'s instruction-frequency hint, written at [loc]. *)

val targets : Wax_utils.Ast.location -> ('idx * int) list -> 'idx t -> 'idx t
(** [targets loc l t] sets [t]'s call-target hint, written at [loc]. *)

val map_targets : ('a -> 'b) -> 'a t -> 'b t
(** [map_targets f t] rewrites the function references of [t]'s call targets,
    for the conversions that change how an index is spelled. *)

(** {1 Instruction frequency}

    The wire byte is an offset base-2 logarithm of the executions-per-call
    ratio: [max 1 (min 64 (floor (log2 r) + 32))], so [32] means once. The
    endpoints saturate. *)

val never_opt : freq
(** [0]: never optimize this instruction, whatever the engine's own heuristics.
*)

val always_opt : freq
(** [127]: always optimize it. *)

val freq_of_ratio : float -> freq
(** The byte standing for a given executions-per-call ratio. *)

val ratio_of_freq : freq -> float option
(** The ratio a byte stands for, or [None] for the two special values and for a
    byte a hand-written binary put outside the formula's range — those have no
    ratio and must round-trip through the raw payload. *)

(** {1 Wire payloads}

    The byte strings the [(@metadata.code.…)] annotations spell, and the binary
    sections store. *)

val freq_of_payload : string -> (freq, string) result
val freq_payload : freq -> string

val call_targets_of_payload : string -> ((int * int) list, string) result
(** Decode a run of LEB128 [(function index, percentage)] pairs. The indices are
    numeric: only the structured text form can name a target. *)

val call_targets_payload : (int * int) list -> string
