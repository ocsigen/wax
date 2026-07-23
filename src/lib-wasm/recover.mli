(** Sync-token classification for the WAT parser's panic-mode error recovery. *)

val sync : Tokens.token -> Wax_utils.Parsing.sync_class
(** Classify a WAT token for {!Wax_utils.Parsing.Make.parse_recover}: every
    opening parenthesis (bare [LPAREN] and the compound [(param]/… tokens) is
    [Open], [RPAREN] is [Close], end-of-input is [Terminal], and everything else
    is [Skip]. WAT being fully parenthesized, the parentheses are the only
    resynchronization points; recovery relies on the nesting-aware skip and on
    auto-closing with {!closers}. *)

val closers : (Tokens.token * string) list
(** The closing brackets ([")"]) {!Wax_utils.Parsing.Make.parse_recover} may
    insert to auto-close a construct still open in front of a boundary or at end
    of input, each paired with its source spelling (used to build the auto-close
    quick fix). Passed as its [?closers] argument. *)

val insert : (Tokens.token * Wax_utils.Message.t * bool * string) list
(** Placeholder tokens {!Wax_utils.Parsing.Make.parse_recover} may insert to
    repair a construct missing a required token — a zero-width [0] for a missing
    numeric operand or index — each with the diagnostic to report. Passed as its
    [?insert] argument. *)

val barrier : Tokens.token * (Tokens.token -> bool) * (Tokens.token -> bool)
(** The barrier {!Wax_utils.Parsing.Make.parse_recover} uses to recognize a
    missing closer (a new field offered where an instruction was expected) and
    restart at that field: the [(] token to re-offer, the predicate for a field
    keyword written after a bare [(] (offered as a pair), and the predicate for
    a fused [(type]/[(import]/[(export] opener (offered alone). Passed as its
    [?barrier] argument. *)
