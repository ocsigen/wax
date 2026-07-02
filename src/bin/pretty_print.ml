module P =
  Wax_wasm.Parsing.Make_parser
    (struct
      type t = Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
    end)
    (Wax_wasm.Tokens)
    (Wax_wasm.Parser)
    (Wax_wasm.Fast_parser)
    (Wax_wasm.Parser_messages)
    (Wax_wasm.Lexer)

let print_module trivia f m =
  let trivia, tail = Wax_utils.Trivia.associate trivia in
  Wax_utils.Printer.run f (fun p ->
      Wax_wasm.Output.module_ ~out_channel:stdout ~tail p ~trivia m)

let convert ~filename =
  let ast, trivia = P.parse ~filename () in
  let folded =
    Wax_utils.Diagnostic.run ~source:None (fun d ->
        Wax_wasm.Folding.fold d (Wax_wasm.Folding.unfold ast))
  in
  Format.printf "/////////// %s //////////@.@.%a@." filename
    (print_module trivia) folded

let _ =
  let p = "/home/jerome/wasm_of_ocaml/runtime/wasm" in
  if false then convert ~filename:(Filename.concat p "int32.wat")
  else
    let l = Sys.readdir p in
    Array.iter
      (fun nm ->
        if Filename.check_suffix nm ".wat" then
          convert ~filename:(Filename.concat p nm))
      l
