(* A Language Server Protocol server for Wax and Wasm text, over stdin/stdout.
   A thin JSON-RPC layer over {!Wax_editor}: it keeps a store of open documents
   and maps each request to the matching analysis function, pushing diagnostics
   on open/change. Backs the [wax lsp] subcommand. *)

(* Run the server: read JSON-RPC packets from stdin and reply on stdout until
   the client closes the stream or sends [exit]. Blocks the calling thread. *)
val run : unit -> unit
