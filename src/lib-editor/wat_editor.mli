(* The Wasm-text (WAT) editor analysis as pure functions over source text,
   shared by the JavaScript wrapper ([wax_format_js], for the VS Code extension)
   and the native LSP server ([Wax_lsp]). The Wax counterpart is {!Wax_editor};
   the shared value types and helpers are in {!Editor_common}. Positions are
   zero-based (line, character) — the character counted in UTF-16 code units by
   default, or the [?encoding] a caller passes. *)

open Editor_common

(* Reprint the module with its comments preserved, or report why it could not
   ([Error message]). *)
val format_string : string -> (string, string) result

(* Parse and validate the buffer, returning every diagnostic — recovering past
   syntax errors so all are reported, not just the first. *)
val check_string : string -> diag list

(* Hover at a (line, character) position: the type the innermost instruction
   under the cursor leaves on the stack. *)
val hover_string :
  ?encoding:position_encoding -> string -> int -> int -> hover option

(* The definition span of the symbol at the position. *)
val definition_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* From a value at the position, the declaration span(s) of its type. *)
val type_definition_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* Every occurrence (definition and uses) of the symbol at the position, for
   find-references and document highlight. *)
val references_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* Inlay hints: after each numeric index that resolves to a named definition,
   that definition's name (so [(local.get 0)] shows [$x]). Empty for a symbolic
   use (the name is already there) or an anonymous target. *)
val inlays_string : string -> inlay list

(* The span of the renameable symbol at the position, or [None]. *)
val rename_prepare_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location option

(* The rename outcome: [Rename_edits] with one [(span, replacement)] per
   symbolic occurrence (empty when the position is not on a renameable symbol),
   or [Rename_conflict] when the new name would collide with an existing name in
   the same flat index space (or otherwise rebind a name). *)
val rename_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  string ->
  rename_outcome

(* Completion candidates at the position: the in-scope names of the index space
   the enclosing instruction expects there (functions, globals, locals, types,
   labels, …), each with its leading [$]. Empty away from an index operand. The
   [string list] is the [wax.define] set, accepted for signature parity with the
   Wax side (WAT completion does not yet specialize on it). *)
val completion_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  string list ->
  completion list

(* The module's top-level definitions, for the outline. *)
val symbols_string : string -> sym list

(* The signature of the folded direct call enclosing the cursor: [(label,
   parameter [start, end) offsets within label, active-argument index)], or
   [None]. *)
val signature_help_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  (string * (int * int) list * int) option

(* The chain of enclosing syntactic spans at the position, innermost first, each
   [(start line, start char, end line, end char)] (zero-based). *)
val selection_range_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  (int * int * int * int) list

(* Foldable ranges — field and block bodies and multi-line block comments — each
   [(start line, end line, kind)] (zero-based). *)
val folding_string : string -> (int * int * string) list

(* Each index identifier classified by the kind of definition it resolves to,
   for semantic highlighting. *)
val semantic_tokens_string :
  ?encoding:position_encoding -> string -> sem_token list

(* Convert the buffer to Wax (decompile Wasm text to Wax), for the side-by-side
   preview, or [Error message]. *)
val to_wax_string : string -> (string, string) result
