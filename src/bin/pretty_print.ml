module P =
  Wasm.Parsing.Make_parser
    (struct
      type t = Wasm.Ast.location Wasm.Ast.Text.module_
    end)
    (Wasm.Tokens)
    (Wasm.Parser)
    (Wasm.Fast_parser)
    (Wasm.Parser_messages)
    (Wasm.Lexer)

let print_module trivia f m =
  let trivia, tail = Utils.Trivia.associate trivia in
  Utils.Printer.run f (fun p ->
      Wasm.Output.module_ ~out_channel:stdout ~tail p ~trivia m)

let convert ~filename =
  let ast, trivia = P.parse ~filename () in
  Format.printf "/////////// %s //////////@.@.%a@." filename
    (print_module trivia)
    (Wasm.Folding.fold (Wasm.Folding.unfold ast))

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
