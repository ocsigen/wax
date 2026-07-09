(* The Wax toolchain's formatter and checker exported to JavaScript, for the VS
   Code extension. It runs in-process under wasm_of_ocaml in both Node (the
   desktop extension host) and the browser (the web extension), and installs
   [globalThis.wax] with two methods:

   - [format src] -> { ok; text; error }: reprint the module with its comments
     preserved (mirrors [wax_to_wax] in bin/main.ml), or report why it could not.
   - [check src] -> array of { severity; message; startLine; startChar; endLine;
     endChar }: parse and type-check, returning diagnostics for the editor.

   Parsing goes through [parse_diagnostics], which yields the AST or a structured
   error without printing or exiting (and without the fast parser), so a syntax
   error becomes an editor squiggle rather than stderr noise. *)

open Js_of_ocaml

(* The editor parses through [parse_diagnostics], which uses the incremental
   parser directly, so it instantiates {!Wax_wasm.Parsing.Make} — the core
   functor without a [Fast_parser] parameter. That keeps [Wax_lang.Fast_parser]
   and its tables out of the linked program (the bytecode linker pulls in a whole
   compilation unit as soon as it is referenced, even only as a functor
   argument). *)
module Wax_parser =
  Wax_wasm.Parsing.Make
    (struct
      type t = Wax_lang.Ast.location Wax_lang.Ast.module_
    end)
    (Wax_lang.Tokens)
    (Wax_lang.Parser)
    (Wax_lang.Parser_messages)
    (Wax_lang.Lexer)

(* A formatter that discards everything, for the dry pass that records which
   source locations the printer looks up (as in bin/main.ml). *)
let null_formatter () = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ())

(* Comments and blank-line trivia keyed by source location, restricted to the
   locations the printer actually visits. Same logic as [wax_trivia] in
   bin/main.ml. *)
let wax_trivia ctx ast =
  let used = Hashtbl.create 256 in
  Wax_utils.Printer.run (null_formatter ()) (fun p ->
      Wax_lang.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used ast);
  Wax_utils.Trivia.associate ~only:used ctx

let format_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } -> Error (String.trim message)
  | Ok (ast, ctx) ->
      let trivia, tail = wax_trivia ctx ast in
      let buf = Buffer.create (String.length src) in
      let fmt = Format.formatter_of_buffer buf in
      let print_wax f m =
        Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
            Wax_lang.Output.module_ p ~trivia ~tail m)
      in
      Format.fprintf fmt "%a@." print_wax ast;
      Ok (Buffer.contents buf)

type diag = {
  severity : Wax_utils.Diagnostic.severity;
  location : Wax_utils.Ast.location;
  message : string;
  hint : string option;
  related : (string * Wax_utils.Ast.location) list;
      (* a message and the source span it points at (e.g. the matching opener) *)
}

let render f = Format.asprintf "%a" f ()

let render_labels labels =
  List.map
    (fun (l : Wax_utils.Diagnostic.label) -> (render l.message, l.location))
    labels

(* Diagnostics: a syntax error (one, from the parser) or, if parsing succeeds,
   the type-checker's errors and warnings collected without printing. Both carry
   any related labels (e.g. "the matching ( is here"); type-checker entries also
   carry a hint. *)
let check_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error e ->
      [
        {
          severity = Wax_utils.Diagnostic.Error;
          location = e.location;
          message = e.message;
          hint = None;
          related = render_labels e.related;
        };
      ]
  | Ok (ast, _ctx) ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      (try Wax_lang.Typing.check ~warn_unused:true d ast
       with Wax_utils.Diagnostic.Aborted -> ());
      List.map
        (fun e ->
          {
            severity = Wax_utils.Diagnostic.entry_severity e;
            location = Wax_utils.Diagnostic.entry_location e;
            message = render (Wax_utils.Diagnostic.entry_message e);
            hint = Option.map render (Wax_utils.Diagnostic.entry_hint e);
            related = render_labels (Wax_utils.Diagnostic.entry_related e);
          })
        (Wax_utils.Diagnostic.collected d)

(* VS Code positions are zero-based for both line and character; Lexing lines are
   one-based and [pos_cnum - pos_bol] is the zero-based column. *)
let js_position (p : Lexing.position) =
  (p.Lexing.pos_lnum - 1, p.Lexing.pos_cnum - p.Lexing.pos_bol)

let js_related (message, (location : Wax_utils.Ast.location)) =
  let start_line, start_char = js_position location.loc_start in
  let end_line, end_char = js_position location.loc_end in
  object%js
    val message = Js.string (String.trim message)
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
  end

let js_diagnostic d =
  let start_line, start_char = js_position d.location.loc_start in
  let end_line, end_char = js_position d.location.loc_end in
  object%js
    val severity =
      Js.string
        (match d.severity with
        | Wax_utils.Diagnostic.Error -> "error"
        | Warning -> "warning")

    val message = Js.string (String.trim d.message)
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char

    val hint =
      match d.hint with
      | Some h -> Js.some (Js.string (String.trim h))
      | None -> Js.null

    val related = Js.array (Array.of_list (List.map js_related d.related))
  end

let result ~ok ~text ~error =
  object%js
    val ok = Js.bool ok

    val text =
      match text with Some t -> Js.some (Js.string t) | None -> Js.null

    val error =
      match error with Some e -> Js.some (Js.string e) | None -> Js.null
  end

(* Never let a failure escape as an uncaught exception: [format] reports
   [ok:false] so the provider leaves the buffer untouched, and [check] returns no
   diagnostics rather than crashing the extension host. *)
let format_result src =
  try
    match format_string (Js.to_string src) with
    | Ok text -> result ~ok:true ~text:(Some text) ~error:None
    | Error message -> result ~ok:false ~text:None ~error:(Some message)
  with exn ->
    result ~ok:false ~text:None ~error:(Some (Printexc.to_string exn))

let check_result src =
  let diagnostics = try check_string (Js.to_string src) with _ -> [] in
  Js.array (Array.of_list (List.map js_diagnostic diagnostics))

let () =
  Js.export "wax"
    object%js
      method format src = format_result src
      method check src = check_result src
    end
