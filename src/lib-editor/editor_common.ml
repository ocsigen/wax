(* Shared infrastructure for the Wax and Wasm-text editor analyses: the value
   types the feature functions return ([diag], [hover], [inlay], [sym],
   [completion], [sem_token]), the position-encoding type, and the small helpers
   both languages use — trivia collection, diagnostic rendering, byte/character
   column conversion, and source slicing. {!Wax_editor} (Wax) and {!Wat_editor}
   (Wasm text) each [open] this module. *)

(* The editor analyses possibly-incomplete, mid-edit WAT buffers, so validation
   stays lenient about [ref.func] targets — matching the CLI's default for WAT
   *text* input (strict only under [--strict-validate] or for a wasm binary). *)
let () = Wax_wasm.Validation.validate_refs := false

(* A formatter that discards everything, for the dry pass that records which
   source locations the printer looks up (as in bin/main.ml). *)
let null_formatter () = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ())

(* Comments and blank-line trivia keyed by source location, restricted to the
   locations [print] (the caller's module printer, [collect]ing the visited
   locations) actually visits. Language-agnostic — the caller supplies the Wax or
   Wasm-text printer — so this stays free of either language's [Output].
   [retarget], when given, rewrites the comment delimiters from the source
   language's syntax to the target's (for the cross-language conversions, whose
   converted nodes carry the source locations). Same logic as [wax_trivia] /
   [wat_trivia] in bin/main.ml. *)
let collect_trivia ~print ?retarget ctx =
  let used = Hashtbl.create 256 in
  Wax_utils.Printer.run (null_formatter ()) (fun p -> print p ~collect:used);
  let trivia, tail = Wax_utils.Trivia.associate ~only:used ctx in
  match retarget with
  | None -> (trivia, tail)
  | Some (src, dst) -> Wax_utils.Trivia.retarget ~src ~dst trivia tail

type diag = {
  severity : Wax_utils.Diagnostic.severity;
  location : Wax_utils.Ast.location;
  message : string;
  warning : string option; (* the [-W] name of a lint warning, if any *)
  unnecessary : bool;
      (* the warning flags removable/unreachable code ([Warning.is_unnecessary]),
         so an editor can render it faded *)
  hint : string option;
  edit : Wax_utils.Diagnostic.edit option;
      (* a machine-applicable rewrite, for a quick fix (a [Suggestion], or a
         fixable warning like a redundant cast) *)
  related : (string * Wax_utils.Ast.location) list;
      (* a message and the source span it points at (e.g. the matching opener) *)
}

let render m = Wax_utils.Message.to_plain_string m

let render_labels labels =
  List.map
    (fun (l : Wax_utils.Diagnostic.label) -> (render l.message, l.location))
    labels

(* A syntax error, as a diagnostic (with its related labels but no hint). *)
let syntax_error_diag (e : Wax_wasm.Parsing.syntax_error) =
  {
    severity = Wax_utils.Diagnostic.Error;
    location = e.location;
    message = Wax_utils.Message.to_plain_string e.message;
    warning = None;
    unnecessary = false;
    hint = None;
    edit = None;
    related = render_labels e.related;
  }

(* The errors and warnings a checker collected (without printing), as diagnostics
   carrying their hints and related labels. *)
let collected_diags d =
  List.map
    (fun e ->
      let warning = Wax_utils.Diagnostic.entry_warning e in
      {
        severity = Wax_utils.Diagnostic.entry_severity e;
        location = Wax_utils.Diagnostic.entry_location e;
        message = render (Wax_utils.Diagnostic.entry_message e);
        warning = Option.map Wax_utils.Warning.name warning;
        unnecessary =
          (match warning with
          | Some w -> Wax_utils.Warning.is_unnecessary w
          | None -> false);
        hint = Option.map render (Wax_utils.Diagnostic.entry_hint e);
        edit = Wax_utils.Diagnostic.entry_edit e;
        related = render_labels (Wax_utils.Diagnostic.entry_related e);
      })
    (Wax_utils.Diagnostic.collected d)

(* Whether a collector holds any error (as opposed to only warnings), and its
   errors joined into one message. Used by the conversions, which need a
   well-typed / valid input and so give up — reporting why — on any error. *)
let has_errors d =
  List.exists
    (fun e ->
      Wax_utils.Diagnostic.entry_severity e = Wax_utils.Diagnostic.Error)
    (Wax_utils.Diagnostic.collected d)

let errors_string d =
  Wax_utils.Diagnostic.collected d
  |> List.filter (fun e ->
      Wax_utils.Diagnostic.entry_severity e = Wax_utils.Diagnostic.Error)
  |> List.map (fun e -> render (Wax_utils.Diagnostic.entry_message e))
  |> String.concat "\n"

(* A hover result: the rendered type and the span it covers. *)
type hover = { h_type : string; h_range : Wax_utils.Ast.location }

(* Which unit an editor counts a line's [character] offset in. UTF-16 is the LSP
   default (and what VS Code uses); UTF-8 counts code units, i.e. bytes, which is
   the internal unit here, so its conversions are the identity. *)
type position_encoding = UTF8 | UTF16

(* Map an incoming editor position to a byte column for comparison with Lexing
   columns: the byte column on zero-based [line] that its [char] denotes. Under
   [UTF16] (the default) [char] counts UTF-16 code units, so convert against the
   line prefix; under [UTF8] it already is the byte column. The inverse of
   [position]'s column conversion. *)
let byte_column ?(encoding = UTF16) src line char =
  match encoding with
  | UTF8 -> char
  | UTF16 ->
      let len = String.length src in
      let rec line_start i n =
        if n <= 0 || i >= len then i
        else line_start (i + 1) (if src.[i] = '\n' then n - 1 else n)
      in
      let start = line_start 0 line in
      let stop =
        match String.index_from_opt src start '\n' with
        | Some j -> j
        | None -> len
      in
      Wax_utils.Unicode.utf16_offset_to_byte
        (String.sub src start (stop - start))
        char

let slice src (loc : Wax_utils.Ast.location) =
  String.sub src loc.loc_start.pos_cnum
    (loc.loc_end.pos_cnum - loc.loc_start.pos_cnum)

(* An inlay hint: the position it sits at and its label (e.g. [": i32"]). *)
type inlay = { n_pos : Lexing.position; n_label : string }

(* Map a Lexing position to a zero-based (line, UTF-16 character) editor
   position — the shape LSP and VS Code use. Lexing lines are one-based and its
   [pos_cnum - pos_bol] is a byte column, which is the [UTF8] character offset
   directly; for [UTF16] the character counts UTF-16 code units, which differ
   from bytes once a line contains a non-ASCII character (Wax allows them in
   identifiers and comments), so convert the line prefix. [src] is the buffer
   being indexed. The inverse of [byte_column]. *)
let position ~encoding src (p : Lexing.position) =
  let bol = p.Lexing.pos_bol and cnum = p.Lexing.pos_cnum in
  let prefix = String.sub src bol (cnum - bol) in
  let column =
    match encoding with
    | UTF8 -> cnum - bol
    | UTF16 -> Wax_utils.Unicode.utf16_length prefix
  in
  (p.Lexing.pos_lnum - 1, column)

(* The UTF-16 specialization, for the VS Code wrapper (which is always UTF-16). *)
let utf16_position src p = position ~encoding:UTF16 src p

(* Document outline: the module's top-level definitions (functions, globals,
   types, memories, tags, tables, elems, data, imports) with their spans, for the
   editor's outline / breadcrumbs. Only a syntactically-valid module yields
   symbols. *)
type sym = {
  s_name : string;
  s_kind : string;
  s_range : Wax_utils.Ast.location; (* the whole definition span *)
  s_selection : Wax_utils.Ast.location; (* the name span *)
  s_children : sym list;
}

(* [k_detail] is a one-line type / signature shown beside the item, or "". *)
type completion = { k_name : string; k_kind : string; k_detail : string }

(* A semantic token: 0-based line, 0-based UTF-16 character, UTF-16 length, and
   the token-type name (from the provider legend). *)
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
   name resolves to (a collision with an existing name, or a local silently
   shadowing another binding). Shared by both languages. *)
type rename_outcome =
  | Rename_conflict of string
  | Rename_edits of (Wax_utils.Ast.location * string) list

(* Map each byte offset in [offsets] (sorted ascending) to its (0-based line,
   0-based column, in [encoding] units) in [src], in a single left-to-right pass
   — so the whole token list is converted in O(src + offsets) rather than
   re-scanning a line prefix per token (quadratic on a long line). *)
let positions ~encoding src offsets =
  let tbl = Hashtbl.create (List.length offsets * 2) in
  let remaining = ref offsets in
  let flush byte line col =
    while match !remaining with o :: _ -> o <= byte | [] -> false do
      match !remaining with
      | o :: rest ->
          Hashtbl.replace tbl o (line, col);
          remaining := rest
      | [] -> ()
    done
  in
  let n = String.length src in
  let byte = ref 0 and line = ref 0 and col = ref 0 in
  while !byte < n && !remaining <> [] do
    flush !byte !line !col;
    let d = String.get_utf_8_uchar src !byte in
    let u = Uchar.utf_decode_uchar d in
    let width = Uchar.utf_decode_length d in
    (if Uchar.to_int u = Char.code '\n' then (
       incr line;
       col := 0)
     else
       col :=
         !col
         +
         match encoding with
         | UTF8 -> width
         | UTF16 -> if Uchar.to_int u > 0xFFFF then 2 else 1);
    byte := !byte + max 1 width
  done;
  flush !byte !line !col;
  tbl
