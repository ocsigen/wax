type binary_module = Wax_wasm.Ast.location Wax_wasm.Ast.Binary.module_

(* Pre-instantiated parsers, matching the wiring in [src/bin/main.ml]. *)

module Wat_parser =
  Wax_wasm.Parsing.Make_parser
    (struct
      type t = Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
    end)
    (Wax_wasm.Tokens)
    (Wax_wasm.Parser)
    (Wax_wasm.Fast_parser)
    (Wax_wasm.Parser_messages)
    (Wax_wasm.Lexer)

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

(* Panic-mode recovery boundaries for Wax; end-of-input stops recovery and
   everything not listed here is skipped while scanning for one of these.

   Two kinds of boundary, both handled by the same "unwind the stack to a state
   that can shift this token, then shift it" step (see
   {!Wax_wasm.Parsing.Make.parse_recover}):

   - Trailing delimiters — [";"] and ["}"] — resync as the tail of the broken
     construct.
   - Leading keywords that unambiguously begin a new top-level item or a [let]
     binding. They let recovery resync at the next construct even when the error
     consumed the trailing [";"]/["}"]. Only keywords that can never continue an
     expression are included: the expression forms [if]/[loop]/[block]/[match]
     are deliberately left out, since in this expression-oriented grammar they
     can occur mid-expression and stopping at one would resync too early. *)
let wax_sync : Wax_lang.Tokens.token -> Wax_wasm.Parsing.sync_class = function
  | Wax_lang.Tokens.SEMI | Wax_lang.Tokens.RBRACE | Wax_lang.Tokens.RPAREN
  | Wax_lang.Tokens.RBRACKET ->
      Boundary
  | Wax_lang.Tokens.FN | Wax_lang.Tokens.TYPE | Wax_lang.Tokens.REC
  | Wax_lang.Tokens.IMPORT | Wax_lang.Tokens.MEMORY | Wax_lang.Tokens.DATA
  | Wax_lang.Tokens.TABLE | Wax_lang.Tokens.ELEM | Wax_lang.Tokens.TAG
  | Wax_lang.Tokens.CONST | Wax_lang.Tokens.LET | Wax_lang.Tokens.RETURN
  | Wax_lang.Tokens.BR | Wax_lang.Tokens.BR_IF | Wax_lang.Tokens.BR_TABLE
  | Wax_lang.Tokens.THROW | Wax_lang.Tokens.THROW_REF | Wax_lang.Tokens.BECOME
  | Wax_lang.Tokens.NOP | Wax_lang.Tokens.UNREACHABLE ->
      Boundary
  | Wax_lang.Tokens.EOF -> Terminal
  | _ -> Skip

let wax_parse_recover ~filename text =
  Wax_parser.parse_recover ~filename ~sync:wax_sync text

let wat_to_binary ?(color = Wax_utils.Colors.Never)
    ?(defines = Wax_wasm.Cond_specialize.of_list []) ?(name_functions = false)
    ?(validate = false) ~filename text =
  let ast, _ctx = Wat_parser.parse_from_string ~color ~filename text in
  let ast =
    if Wax_wasm.Cond_specialize.is_empty defines then ast
    else
      Wax_utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
          fst (Wax_wasm.Cond_specialize.module_ d defines ast))
  in
  let ast =
    if name_functions then Wax_wasm.Naming.name_functions_from_exports ast
    else ast
  in
  if validate then
    Wax_utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wax_wasm.Validation.f d ast);
  Wax_wasm.Text_to_binary.module_ ast

let wax_to_binary ?(color = Wax_utils.Colors.Never)
    ?(defines = Wax_wasm.Cond_specialize.of_list []) ?(validate = false)
    ~filename text =
  let ast, _ctx = Wax_parser.parse_from_string ~color ~filename text in
  let ast =
    if Wax_wasm.Cond_specialize.is_empty defines then ast
    else
      Wax_utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
          fst (Wax_lang.Cond_specialize.module_ d defines ast))
  in
  let types, ast =
    Wax_utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wax_lang.Typing.f ~warn_unused:validate d ast)
  in
  let wasm_ast =
    Wax_utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        To_wasm.module_ d types ast)
  in
  if validate then
    Wax_utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        (* Unused locals are reported against the Wax source by [Typing.f]
           above; do not repeat them against the compiled Wasm. *)
        Wax_wasm.Validation.f ~warn_unused:false d wasm_ast);
  Wax_wasm.Text_to_binary.module_ wasm_ast

let output_binary ~out_channel ?opt_source_map_file ast =
  Wax_wasm.Wasm_output.module_ ~out_channel ?opt_source_map_file ast
