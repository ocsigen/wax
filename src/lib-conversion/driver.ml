type binary_module = Wax_wasm.Ast.location Wax_wasm.Ast.Binary.module_

(* Pre-instantiated parsers, matching the wiring in [src/bin/main.ml]. *)

module Wat_parser =
  Wax_utils.Parsing.Make_parser
    (struct
      type t = Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
    end)
    (Wax_wasm.Tokens)
    (Wax_wasm.Parser)
    (Wax_wasm.Fast_parser)
    (Wax_wasm.Parser_messages)
    (Wax_wasm.Lexer)

module Wax_parser =
  Wax_utils.Parsing.Make_parser
    (struct
      type t = Wax_lang.Ast.location Wax_lang.Ast.module_
    end)
    (Wax_lang.Tokens)
    (Wax_lang.Parser)
    (Wax_lang.Fast_parser)
    (Wax_lang.Parser_messages)
    (Wax_lang.Lexer)

let wax_parse_recover ~filename text =
  Wax_parser.parse_recover ~filename ~sync:Wax_lang.Recover.sync
    ~insert:Wax_lang.Recover.insert ~closers:Wax_lang.Recover.closers text

let wat_parse_recover ~filename text =
  Wat_parser.parse_recover ~filename ~sync:Wax_wasm.Recover.sync
    ~insert:Wax_wasm.Recover.insert ~closers:Wax_wasm.Recover.closers
    ~barrier:Wax_wasm.Recover.barrier text

let wat_to_binary ?(color = Wax_utils.Colors.Never)
    ?(defines = Wax_wasm.Cond_specialize.of_list []) ?(name_functions = false)
    ?(validate = false) ~filename text =
  let ast, _ctx = Wat_parser.parse_from_string ~color ~filename text in
  let ast =
    if Wax_wasm.Cond_specialize.is_empty defines then ast
    else
      Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
        ~source:(Some text) (fun d ->
          fst (Wax_wasm.Cond_specialize.module_ d defines ast))
  in
  let ast =
    if name_functions then Naming.name_functions_from_exports ast else ast
  in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:(Some text) (fun d -> Wax_wasm.Validation.f d ast);
  Wax_wasm.Text_to_binary.module_ ast

let wax_to_binary ?(color = Wax_utils.Colors.Never)
    ?(defines = Wax_wasm.Cond_specialize.of_list []) ?(validate = false)
    ~filename text =
  let ast, _ctx = Wax_parser.parse_from_string ~color ~filename text in
  let ast =
    if Wax_wasm.Cond_specialize.is_empty defines then ast
    else
      Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
        ~source:(Some text) (fun d ->
          fst (Wax_lang.Cond_specialize.module_ d defines ast))
  in
  let types, ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d ->
        Wax_lang.Typing.f ~warn_unused:validate d ast)
  in
  let wasm_ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d -> To_wasm.module_ d types ast)
  in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:(Some text) (fun d ->
        (* Unused locals are reported against the Wax source by [Typing.f]
           above; do not repeat them against the compiled Wasm. *)
        Wax_wasm.Validation.f ~warn_unused:false d wasm_ast);
  Wax_wasm.Text_to_binary.module_ wasm_ast

let output_binary ~out_channel ?(source_map = false) ast =
  Wax_wasm.Wasm_output.module_ ~out_channel ~source_map ast
