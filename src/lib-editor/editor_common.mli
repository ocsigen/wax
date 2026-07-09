(* Shared infrastructure for the Wax and Wasm-text editor analyses: the value
   types the feature functions return, the position-encoding type, and the small
   helpers both languages use. {!Wax_editor} (Wax) and {!Wat_editor} (Wasm text)
   each [open] this module. *)

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
  edit : Wax_utils.Diagnostic.edit option;
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

(* The outcome of a rename. [Rename_edits] carries [(span, replacement)] for
   every occurrence, and is empty when the position is not on a renameable
   symbol. [Rename_conflict] carries a message rejecting the rename: [newname] is
   not a usable identifier, or carrying it out would change which definition some
   name resolves to. Shared by {!Wax_editor} and {!Wat_editor}. *)
type rename_outcome =
  | Rename_conflict of string
  | Rename_edits of (Wax_utils.Ast.location * string) list

(* Which unit an editor counts a line's character offset in. [UTF16] is the LSP
   default and what VS Code uses; [UTF8] counts bytes (the internal unit). The
   position functions and the [?encoding] arguments default to [UTF16]. *)
type position_encoding = UTF8 | UTF16

(* A formatter that discards everything, for the dry pass that records which
   source locations the printer looks up. *)
val null_formatter : unit -> Format.formatter

(* Comments and blank-line trivia keyed by source location, restricted to the
   locations [print] visits (it prints the module through the given printer,
   passing its [collect] table on to the language's [Output.module_]).
   Language-agnostic: the caller chooses the Wax or Wasm-text printer, so this
   module needs neither language's [Output]. [retarget], when given, rewrites the
   comment delimiters from the source syntax to the target's. *)
val collect_trivia :
  print:
    (Wax_utils.Printer.t ->
    collect:(Wax_utils.Ast.location, unit) Hashtbl.t ->
    unit) ->
  ?retarget:Wax_utils.Trivia.comment_syntax * Wax_utils.Trivia.comment_syntax ->
  Wax_utils.Trivia.context ->
  Wax_utils.Trivia.t * Wax_utils.Trivia.entry list

(* Render a structured message to plain text. *)
val render : Wax_utils.Message.t -> string

(* Render diagnostic labels to [(message, span)] pairs. *)
val render_labels :
  Wax_utils.Diagnostic.label list -> (string * Wax_utils.Ast.location) list

(* A syntax error, as a diagnostic (with its related labels but no hint). *)
val syntax_error_diag : Wax_wasm.Parsing.syntax_error -> diag

(* The errors and warnings a checker collected (without printing), as
   diagnostics carrying their hints and related labels. *)
val collected_diags : Wax_utils.Diagnostic.context -> diag list

(* Whether a collector holds any error (as opposed to only warnings). *)
val has_errors : Wax_utils.Diagnostic.context -> bool

(* The collector's errors joined into one message. *)
val errors_string : Wax_utils.Diagnostic.context -> string

(* Map an incoming editor position to a byte column for comparison with Lexing
   columns. The inverse of [position]'s column conversion. *)
val byte_column : ?encoding:position_encoding -> string -> int -> int -> int

(* The source text a location spans. *)
val slice : string -> Wax_utils.Ast.location -> string

(* Map a Lexing position to a zero-based (line, character) editor position
   against [src], the character counted in [encoding] units. The inverse of the
   columns the [*_string] functions accept. *)
val position :
  encoding:position_encoding -> string -> Lexing.position -> int * int

(* The UTF-16 specialization ([position ~encoding:UTF16]), for the VS Code
   wrapper, which is always UTF-16. *)
val utf16_position : string -> Lexing.position -> int * int

(* Map each byte offset in [offsets] (sorted ascending) to its (0-based line,
   0-based column, in [encoding] units) in [src], in a single left-to-right
   pass. *)
val positions :
  encoding:position_encoding -> string -> int list -> (int, int * int) Hashtbl.t
