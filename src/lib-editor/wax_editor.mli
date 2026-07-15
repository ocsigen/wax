(* The Wax toolchain's editor analysis as pure functions over source text,
   shared by the JavaScript wrapper ([wax_format_js], for the VS Code extension)
   and the native LSP server ([Wax_lsp]). Positions are zero-based (line,
   character) — the shape an LSP client and VS Code both use; the character is
   counted in UTF-16 code units by default, or the [?encoding] a caller passes
   ([UTF8] counts bytes). A returned {!Wax_utils.Ast.location} is mapped back to
   that shape with {!position} (or {!utf16_position} for the UTF-16 case).

   Features are provided as Wax / Wasm-text pairs where both apply. The Wasm-text
   side validates instead of type-checking and builds no typed tree, so the
   features that read the typed tree (hover, inlay hints, go-to-definition,
   references, rename, completion, signature help, semantic tokens, selection
   and folding ranges, inactive ranges) are Wax only. *)

(* A diagnostic: a syntax error, type error, or lint warning, with its span, an
   optional [-W] warning name, an optional hint, and related labels (each a
   message and the span it points at, e.g. a matching opener). *)
type diag = {
  severity : Wax_utils.Diagnostic.severity;
  location : Wax_utils.Ast.location;
  message : string;
  warning : string option;
  unnecessary : bool;
      (* the warning marks removable/unreachable code, for faded rendering *)
  hint : string option;
  related : (string * Wax_utils.Ast.location) list;
}

(* A hover result: the rendered type and the span it covers. *)
type hover = { h_type : string; h_range : Wax_utils.Ast.location }

(* An inlay hint: the position it sits at and its label (e.g. [": i32"]). *)
type inlay = { n_pos : Lexing.position; n_label : string }

(* An outline symbol: name, kind (an LSP-ish kind word such as ["function"] /
   ["variable"] / ["type"]), full definition span, name span, and children. *)
type sym = {
  s_name : string;
  s_kind : string;
  s_range : Wax_utils.Ast.location;
  s_selection : Wax_utils.Ast.location;
  s_children : sym list;
}

(* A completion candidate: name, kind word, and a one-line type / signature
   detail (empty when none). *)
type completion = { k_name : string; k_kind : string; k_detail : string }

(* A semantic token: zero-based line, zero-based UTF-16 character, UTF-16
   length, and the token-type name. *)
type sem_token = {
  st_line : int;
  st_char : int;
  st_len : int;
  st_type : string;
}

(* Which unit an editor counts a line's character offset in. [UTF16] is the LSP
   default and what VS Code uses; [UTF8] counts bytes (the internal unit). The
   position functions and the [?encoding] arguments below default to [UTF16]. *)
type position_encoding = UTF8 | UTF16

(* Map a Lexing position to a zero-based (line, character) editor position
   against [src], the character counted in [encoding] units. The inverse of the
   columns the [*_string] functions accept. *)
val position :
  encoding:position_encoding -> string -> Lexing.position -> int * int

(* The UTF-16 specialization ([position ~encoding:UTF16]), for the VS Code
   wrapper, which is always UTF-16. *)
val utf16_position : string -> Lexing.position -> int * int

(* Reprint the module with its comments preserved, or report why it could not
   ([Error message]). [format_wat_string] is the Wasm-text form. *)
val format_string : string -> (string, string) result
val format_wat_string : string -> (string, string) result

(* Parse and check (type-check for Wax, validate for Wasm text), returning every
   diagnostic — recovering past syntax errors so all are reported, not just the
   first. *)
val check_string : string -> diag list
val check_wat_string : string -> diag list

(* [check_string] specialized to a conditional-compilation configuration (the
   [defines] are ["NAME"] / ["NAME=value"] strings, as on the [-D] CLI); with no
   parseable defines this is exactly [check_string]. *)
val check_string_with_defines : string -> string list -> diag list

(* Hover at a (line, character) position: the type of the innermost expression
   there, or what a name (a type reference, an assignment target, a bare global)
   resolves to; [None] over a statement or an unresolved node. Wax only. *)
val hover_string :
  ?encoding:position_encoding -> string -> int -> int -> hover option

(* As [hover_string], but for a Wasm-text buffer: the type the innermost
   instruction under the cursor leaves on the stack. *)
val hover_wat_string :
  ?encoding:position_encoding -> string -> int -> int -> hover option

(* The inferred type on each un-annotated [let] binding. Wax only. *)
val inlays_string : string -> inlay list

(* The definition span(s) for the name or label use at the position (several
   only across conditional-compilation branches). Wax only. *)
val definition_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* As [definition_string], but for a Wasm-text buffer. *)
val definition_wat_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* As [type_definition_string], but for a Wasm-text buffer. *)
val type_definition_wat_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* As [references_string], but for a Wasm-text buffer. *)
val references_wat_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* As [rename_prepare_string], but for a Wasm-text buffer. *)
val rename_prepare_wat_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location option

(* As [rename_string], but for a Wasm-text buffer. *)
val rename_wat_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  string ->
  (Wax_utils.Ast.location * string) list

(* From a value at the position, the declaration span(s) of its type. Wax only. *)
val type_definition_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* Every occurrence (definitions and uses) of the symbol at the position, for
   find-references and document highlight. Wax only. *)
val references_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  Wax_utils.Ast.location list

(* The span of the renameable symbol at the position, or [None]. Wax only. *)
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
   binding). Wax only. *)
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

(* The module's top-level definitions, for the outline. [symbols_wat_string] is
   the Wasm-text form. *)
val symbols_string : string -> sym list
val symbols_wat_string : string -> sym list

(* Completion candidates at the position (member access, [ns::] namespace, or
   names in scope); the [defines] scope module definitions by conditional
   compilation. Wax only. *)
val completion_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  string list ->
  completion list

(* The enclosing call's signature at the position: [(label, parameter [start,
   end) offsets within label, active-argument index)], or [None]. Wax only. *)
val signature_help_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  (string * (int * int) list * int) option

(* As [signature_help_string], but for a Wasm-text buffer: the signature of the
   folded direct call enclosing the cursor. *)
val signature_help_wat_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  (string * (int * int) list * int) option

(* The chain of enclosing syntactic spans at the position, innermost first, each
   [(start line, start char, end line, end char)] (zero-based, UTF-16), for
   expand/shrink selection. Wax only. *)
val selection_range_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  (int * int * int * int) list

(* As [selection_range_string], but for a Wasm-text buffer. *)
val selection_range_wat_string :
  ?encoding:position_encoding ->
  string ->
  int ->
  int ->
  (int * int * int * int) list

(* Every identifier occurrence classified for semantic highlighting. Wax only. *)
val semantic_tokens_string :
  ?encoding:position_encoding -> string -> sem_token list

(* As [semantic_tokens_string], but for WAT: each index identifier classified by
   the kind of definition it resolves to. *)
val semantic_tokens_wat_string :
  ?encoding:position_encoding -> string -> sem_token list

(* Foldable ranges — block bodies and multi-line block comments — each [(start
   line, end line, kind)] (zero-based). Wax only. *)
val folding_string : string -> (int * int * string) list

(* As [folding_string], but for a Wasm-text buffer. *)
val folding_wat_string : string -> (int * int * string) list

(* The source ranges made unreachable by the [defines], each [(start line, start
   char, end line, end char)] (zero-based, UTF-16); empty with no define set.
   Wax only. *)
val inactive_ranges_string :
  ?encoding:position_encoding ->
  string ->
  string list ->
  (int * int * int * int) list

(* Convert between the languages (Wax to Wasm text, Wasm text to Wax), for the
   side-by-side preview, or [Error message]. *)
val to_wat_string : string -> (string, string) result
val to_wax_string : string -> (string, string) result
