(** Sync-token classification for the Wax parser's panic-mode error recovery. *)

val sync : Tokens.token -> Wax_wasm.Parsing.sync_class
(** Classify a Wax token for {!Wax_wasm.Parsing.Make.parse_recover}: the
    statement, block, paren and bracket closers and the keywords that begin a
    new top-level item or statement are resynchronization [Boundary]s,
    end-of-input is the [Terminal], and everything else is [Skip]ped while
    scanning for the next boundary. Shared by the CLI and the editor. *)

val insert : (Tokens.token * Wax_utils.Message.t) list
(** The token {!Wax_wasm.Parsing.Make.parse_recover} may insert in front of an
    offending token — the statement separator [";"] with its display string — so
    a dropped [;] is recovered by inserting one (reported as "Missing ';'")
    rather than by skipping to a boundary. Passed as its [?insert] argument. *)

val closers : Tokens.token list
(** The closing-bracket tokens that {!Wax_wasm.Parsing.Make.parse_recover} may
    insert to auto-close a construct left open at end of input, so it still
    reaches the best-effort AST. Passed as its [?closers] argument. *)
