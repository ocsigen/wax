(* Print every keyword and instruction mnemonic the WAT lexer recognizes, one
   per line ({!Wax_wasm.Lexer.keywords}). A developer/harness tool: the fuzz
   harness's generated opcode grid ([fuzz/op-width.sh]) derives its operation
   list from this instead of a hand-maintained one, so a mnemonic added to the
   lexer — a new proposal's instructions, say — reaches the grid (or fails its
   acknowledged-exemption check) automatically. *)
let () = List.iter print_endline (Wax_wasm.Lexer.keywords ())
