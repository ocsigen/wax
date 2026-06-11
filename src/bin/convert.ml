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

let convert ~filename =
  let source = In_channel.with_open_bin filename In_channel.input_all in
  let ast, _ctx = P.parse_from_string ~filename source in
  Wasm.Validation.validate_refs := false;
  Utils.Diagnostic.run ~source:(Some source) (fun d -> Wasm.Validation.f d ast);
  let ast' =
    Utils.Diagnostic.run ~source:(Some source) (fun d ->
        Conversion.From_wasm.module_ d ast)
  in
  let _, ast3 =
    Utils.Diagnostic.run ~source:(Some source) (fun d -> Wax.Typing.f d ast')
  in
  let ast3 = Wax.Typing.erase_types ast3 in
  let print_wax f m =
    Utils.Printer.run ~width:Wax.Output.width f (fun p ->
        Wax.Output.module_ ~out_channel:stdout p ~trivia:(Hashtbl.create 0) m)
  in
  Format.eprintf "%s==== %s ====%s@.@.%a@.@." Utils.Colors.Ansi.grey filename
    Utils.Colors.Ansi.reset print_wax ast3;
  let ast5 =
    Utils.Diagnostic.run ~source:(Some source) (fun d ->
        let types, ast4 = Wax.Typing.f d ast3 in
        Conversion.To_wasm.module_ d types ast4)
  in
  let print_wasm f m =
    Utils.Printer.run f (fun p ->
        Wasm.Output.module_ ~out_channel:stdout p ~trivia:(Hashtbl.create 0) m)
  in
  if false then Format.eprintf "%a@." print_wasm ast5;
  Utils.Diagnostic.run ~source:(Some source) (fun d -> Wasm.Validation.f d ast5)

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
