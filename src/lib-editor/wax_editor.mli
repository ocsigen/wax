(* The Wax-language editor analysis as pure functions over source text, shared
   by the JavaScript wrapper ([wax_format_js], for the VS Code extension) and the
   native LSP server ([Wax_lsp]). The Wasm-text counterpart is {!Wat_editor}; the
   shared value types and helpers are in {!Editor_common}. Positions are
   zero-based (line, character) — the shape an LSP client and VS Code both use;
   the character is counted in UTF-16 code units by default, or the [?encoding] a
   caller passes ([UTF8] counts bytes). A returned {!Wax_utils.Ast.location} is
   mapped back to that shape with {!Editor_common.position} (or
   {!Editor_common.utf16_position} for the UTF-16 case).

   The Wax side type-checks and builds a typed tree, so features that read it
   (hover, inlay hints, go-to-definition, references, rename, completion,
   signature help, semantic tokens, selection and folding ranges, inactive
   ranges) are Wax only; the Wasm-text side ({!Wat_editor}) validates instead. *)

open Editor_common

(* Reprint the module with its comments preserved, or report why it could not
   ([Error message]). *)
val format_string : string -> (string, string) result

(* Parse and type-check, returning every diagnostic — recovering past syntax
   errors so all are reported, not just the first. *)
val check_string : string -> diag list

(* [check_string] specialized to a conditional-compilation configuration (the
   [defines] are ["NAME"] / ["NAME=value"] strings, as on the [-D] CLI); with no
   parseable defines this is exactly [check_string]. *)
val check_string_with_defines : string -> string list -> diag list

(* Hover at a (line, character) position: the type of the innermost expression
   there, or what a name (a type reference, an assignment target, a bare global)
   resolves to; [None] over a statement or an unresolved node. *)
val hover_string :
  ?encoding:position_encoding -> string -> int -> int -> hover option

(* The inferred type on each un-annotated [let] binding. *)
val inlays_string : string -> inlay list

(* The definition span(s) for the name or label use at the position (several
   only across conditional-compilation branches). *)
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

(* Every occurrence (definitions and uses) of the symbol at the position, for
   find-references and document highlight. *)
val references_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* The span of the renameable symbol at the position, or [None]. *)
val rename_prepare_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location option

(* The outcome of a rename. [Rename_edits] carries [(span, replacement)] for
   every occurrence (a punned struct field expanded to [x: newname]), and is
   empty when the position is not on a renameable symbol. [Rename_conflict]
   carries a message rejecting the rename: [newname] is not a usable identifier,
   or carrying it out would change which definition some name resolves to (a
   collision with an existing name, or a local silently shadowing another
   binding). *)
type rename_outcome =
  | Rename_conflict of string
  | Rename_edits of (Wax_utils.Ast.location * string) list

val rename_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  string ->
  rename_outcome

(* The module's top-level definitions, for the outline. *)
val symbols_string : string -> sym list

(* Completion candidates at the position (member access, [ns::] namespace, or
   names in scope); the [defines] scope module definitions by conditional
   compilation. *)
val completion_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  string list ->
  completion list

(* The enclosing call's signature at the position: [(label, parameter [start,
   end) offsets within label, active-argument index)], or [None]. *)
val signature_help_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  (string * (int * int) list * int) option

(* The chain of enclosing syntactic spans at the position, innermost first, each
   [(start line, start char, end line, end char)] (zero-based, UTF-16), for
   expand/shrink selection. *)
val selection_range_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  (int * int * int * int) list

(* Every identifier occurrence classified for semantic highlighting. *)
val semantic_tokens_string :
  ?encoding:position_encoding -> string -> sem_token list

(* Foldable ranges — block bodies and multi-line block comments — each [(start
   line, end line, kind)] (zero-based). *)
val folding_string : string -> (int * int * string) list

(* The source ranges made unreachable by the [defines], each [(start line, start
   char, end line, end char)] (zero-based, UTF-16); empty with no define set. *)
val inactive_ranges_string :
  ?encoding:position_encoding ->
  string ->
  string list ->
  (int * int * int * int) list

(* Convert the buffer to Wasm text (compile Wax to Wasm text), for the
   side-by-side preview, or [Error message]. *)
val to_wat_string : string -> (string, string) result
