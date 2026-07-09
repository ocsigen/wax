(* A string -> string Wax formatter exported to JavaScript, for the VS Code
   extension. It mirrors [wax_to_wax] in bin/main.ml (parse, then reprint with
   the source comments preserved) but renders to a string and touches no
   filesystem or process state, so it runs in-process under wasm_of_ocaml in
   both Node (the desktop extension host) and the browser (the web extension).

   The single entry point installs [globalThis.wax]; see editors/vscode. *)

open Js_of_ocaml

module Wax_parser =
  Wax_wasm.Parsing.Make_parser
    (struct
      type t = Wax_lang.Ast.location Wax_lang.Ast.module_
    end)
    (Wax_lang.Tokens)
    (Wax_lang.Parser)
    (Wax_lang.Fast_parser)
    (Wax_lang.Parser_messages)
    (Wax_lang.Lexer)

(* A formatter that discards everything, for the dry pass that records which
   source locations the printer looks up (as in bin/main.ml). *)
let null_formatter () = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ())

(* Comments and blank-line trivia keyed by source location, restricted to the
   locations the printer actually visits so a comment never attaches to a node
   the printer skips. Same logic as [wax_trivia] in bin/main.ml. *)
let wax_trivia ctx ast =
  let used = Hashtbl.create 256 in
  Wax_utils.Printer.run (null_formatter ()) (fun p ->
      Wax_lang.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used ast);
  Wax_utils.Trivia.associate ~only:used ctx

let format_string src =
  let ast, ctx = Wax_parser.parse_from_string ~filename:"<buffer>" src in
  let trivia, tail = wax_trivia ctx ast in
  let buf = Buffer.create (String.length src) in
  let fmt = Format.formatter_of_buffer buf in
  let print_wax f m =
    Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
        Wax_lang.Output.module_ p ~trivia ~tail m)
  in
  Format.fprintf fmt "%a@." print_wax ast;
  Buffer.contents buf

(* Never let a parse or format failure escape as an uncaught exception (a syntax
   error already reported itself to stderr and then raised): report [ok:false]
   so the provider leaves the buffer untouched instead of clobbering it. *)
let format_result src =
  try
    let text = format_string (Js.to_string src) in
    object%js
      val ok = Js._true
      val text = Js.some (Js.string text)
      val error = Js.null
    end
  with exn ->
    object%js
      val ok = Js._false
      val text = Js.null
      val error = Js.some (Js.string (Printexc.to_string exn))
    end

let () =
  Js.export "wax"
    object%js
      method format src = format_result src
    end
