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

(* The editor path parses through [parse_diagnostics], which uses the incremental
   parser directly and never touches the fast parser. Passing a stub as the
   [Fast_parser] argument (instead of [Wax_lang.Fast_parser]) keeps the fast
   parser's tables out of the linked program: the bytecode linker pulls in a
   whole compilation unit as soon as it is referenced, even only as a functor
   argument, so referencing the real module would link its tables regardless. *)
module No_fast_parser = struct
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) =
  struct
    type token = Wax_lang.Tokens.token

    exception Error

    let parse _ _ = raise Error
  end
end

module Wax_parser =
  Wax_wasm.Parsing.Make_parser
    (struct
      type t = Wax_lang.Ast.location Wax_lang.Ast.module_
    end)
    (Wax_lang.Tokens)
    (Wax_lang.Parser)
    (No_fast_parser)
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

(* Diagnostics: a syntax error (one, from the parser) or, if parsing succeeds,
   the type-checker's errors and warnings collected without printing. *)
let check_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error e -> [ (Wax_utils.Diagnostic.Error, e.location, e.message) ]
  | Ok (ast, _ctx) ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      (try Wax_lang.Typing.check ~warn_unused:true d ast
       with Wax_utils.Diagnostic.Aborted -> ());
      List.map
        (fun e ->
          let message =
            Format.asprintf "%a" (Wax_utils.Diagnostic.entry_message e) ()
          in
          ( Wax_utils.Diagnostic.entry_severity e,
            Wax_utils.Diagnostic.entry_location e,
            message ))
        (Wax_utils.Diagnostic.collected d)

(* VS Code positions are zero-based for both line and character; Lexing lines are
   one-based and [pos_cnum - pos_bol] is the zero-based column. *)
let js_position (p : Lexing.position) =
  (p.Lexing.pos_lnum - 1, p.Lexing.pos_cnum - p.Lexing.pos_bol)

let js_diagnostic (severity, (location : Wax_utils.Ast.location), message) =
  let start_line, start_char = js_position location.loc_start in
  let end_line, end_char = js_position location.loc_end in
  object%js
    val severity =
      Js.string
        (match severity with
        | Wax_utils.Diagnostic.Error -> "error"
        | Warning -> "warning")

    val message = Js.string (String.trim message)
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
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
