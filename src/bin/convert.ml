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

let convert ~filename =
  let source = In_channel.with_open_bin filename In_channel.input_all in
  let ast, _ctx = P.parse_from_string ~filename source in
  Wax_wasm.Validation.validate_refs := false;
  Wax_utils.Diagnostic.run ~source:(Some source) (fun d ->
      Wax_wasm.Validation.f d ast);
  let ast' =
    Wax_utils.Diagnostic.run ~source:(Some source) (fun d ->
        Wax_conversion.From_wasm.module_ d ast)
  in
  let _, ast3 =
    Wax_utils.Diagnostic.run ~source:(Some source) (fun d ->
        Wax_lang.Typing.f d ast')
  in
  let ast3 = Wax_lang.Typing.erase_types ast3 in
  let print_wax f m =
    Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
        Wax_lang.Output.module_ ~out_channel:stdout p ~trivia:(Hashtbl.create 0)
          m)
  in
  Format.eprintf "%s==== %s ====%s@.@.%a@.@." Wax_utils.Colors.Ansi.grey
    filename Wax_utils.Colors.Ansi.reset print_wax ast3;
  let ast5 =
    Wax_utils.Diagnostic.run ~source:(Some source) (fun d ->
        let types, ast4 = Wax_lang.Typing.f d ast3 in
        Wax_conversion.To_wasm.module_ d types ast4)
  in
  let print_wasm f m =
    Wax_utils.Printer.run f (fun p ->
        Wax_wasm.Output.module_ ~out_channel:stdout p ~trivia:(Hashtbl.create 0)
          m)
  in
  if false then Format.eprintf "%a@." print_wasm ast5;
  Wax_utils.Diagnostic.run ~source:(Some source) (fun d ->
      Wax_wasm.Validation.f d ast5)

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
