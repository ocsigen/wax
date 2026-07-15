(** Sync-token classification for the WAT parser's panic-mode error recovery. *)

val sync : Tokens.token -> Parsing.sync_class
(** Classify a WAT token for {!Parsing.Make.parse_recover}: every opening
    parenthesis (bare [LPAREN] and the compound [(param]/… tokens) is [Open],
    [RPAREN] is [Close], end-of-input is [Terminal], and everything else is
    [Skip]. WAT being fully parenthesized, the parentheses are the only
    resynchronization points; recovery relies on the nesting-aware skip and on
    auto-closing with {!closers}. *)

val closers : Tokens.token list
(** The closing brackets ([")"]) {!Parsing.Make.parse_recover} may insert to
    auto-close a construct still open in front of a boundary or at end of input.
    Passed as its [?closers] argument. *)

val insert : (Tokens.token * Wax_utils.Message.t) list
(** Placeholder tokens {!Parsing.Make.parse_recover} may insert to repair a
    construct missing a required token — a zero-width [0] for a missing numeric
    operand or index — each with the diagnostic to report. Passed as its
    [?insert] argument. *)
