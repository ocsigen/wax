(** Sync-token classification for the Wax parser's panic-mode error recovery. *)

val sync : Tokens.token -> Wax_wasm.Parsing.sync_class
(** Classify a Wax token for {!Wax_wasm.Parsing.Make.parse_recover}: the
    statement, block, paren and bracket closers and the keywords that begin a
    new top-level item or statement are resynchronization [Boundary]s,
    end-of-input is the [Terminal], and everything else is [Skip]ped while
    scanning for the next boundary. Shared by the CLI and the editor. *)
