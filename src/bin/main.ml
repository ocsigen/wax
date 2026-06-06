open Cmdliner
open Term.Syntax

module Wat_parser =
  Wasm.Parsing.Make_parser
    (struct
      type t = Wasm.Ast.location Wasm.Ast.Text.module_
    end)
    (Wasm.Tokens)
    (Wasm.Parser)
    (Wasm.Fast_parser)
    (Wasm.Parser_messages)
    (Wasm.Lexer)

module Wax_parser =
  Wasm.Parsing.Make_parser
    (struct
      type t = Wax.Ast.location Wax.Ast.module_
    end)
    (Wax.Tokens)
    (Wax.Parser)
    (Wax.Fast_parser)
    (Wax.Parser_messages)
    (Wax.Lexer)

let with_open_in file f =
  match file with
  | Some file -> In_channel.with_open_bin file f
  | None -> f stdin

let with_open_out file f =
  match file with
  | Some file -> Out_channel.with_open_bin file f
  | None -> f stdout

type fold_mode = Auto | Fold | Unfold

let output_wat ~fold_mode ~output_file ~color ~trivia ast =
  let ast =
    match fold_mode with
    | Auto -> ast
    | Fold -> Wasm.Folding.fold ast
    | Unfold -> Wasm.Folding.unfold ast
  in
  with_open_out output_file (fun oc ->
      let print_wat f m =
        Utils.Printer.run f (fun p ->
            Wasm.Output.module_ ~color ~out_channel:oc p ~trivia m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wat ast)

let wat_to_wat ~input_file ~output_file ~validate ~color ~fold_mode
    ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  (* Ignored for non-wasm output *)
  let text = with_open_in input_file In_channel.input_all in
  let ast, ctx =
    Wat_parser.parse_from_string
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  if validate then
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wasm.Validation.f d ast);
  output_wat ~fold_mode ~output_file ~color
    ~trivia:(Utils.Trivia.associate ctx)
    ast

let wat_to_wax ~input_file ~output_file ~validate ~color ~fold_mode:_
    ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  (* Ignored for non-wasm output *)
  let text = with_open_in input_file In_channel.input_all in
  let ast, _ctx =
    Wat_parser.parse_from_string
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  if validate then
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wasm.Validation.f d ast);
  let wax_ast =
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Conversion.From_wasm.module_ d ast)
  in
  let wax_ast =
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wax.Typing.f d wax_ast)
    |> snd |> Wax.Typing.erase_types
  in
  with_open_out output_file (fun oc ->
      let print_wax f m =
        Utils.Printer.run f (fun p ->
            Wax.Output.module_ p ~color ~out_channel:oc m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wax wax_ast)

let wax_to_wat ~input_file ~output_file ~validate ~color ~fold_mode
    ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  (* Ignored for non-wasm output *)
  let text = with_open_in input_file In_channel.input_all in
  let ast, _ctx =
    Wax_parser.parse_from_string
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  let types, ast =
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wax.Typing.f d ast)
  in
  let wasm_ast =
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Conversion.To_wasm.module_ d types ast)
  in
  if validate then
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wasm.Validation.f d wasm_ast);
  let trivia = (*ZZZ*) Hashtbl.create 0 in
  output_wat ~fold_mode ~output_file ~color ~trivia wasm_ast

let wax_to_wax ~input_file ~output_file ~validate ~color ~fold_mode:_
    ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  (* Ignored for non-wasm output *)
  let text = with_open_in input_file In_channel.input_all in
  let ast, _ctx =
    Wax_parser.parse_from_string
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  if validate then
    ignore
      (Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
           Wax.Typing.f d ast));
  with_open_out output_file (fun oc ->
      let print_wax f m =
        Utils.Printer.run f (fun p ->
            Wax.Output.module_ p ~color ~out_channel:oc m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wax ast)

let wax_to_wasm ~input_file ~output_file ~validate ~color ~fold_mode:_
    ~source_map_file:(opt_source_map_file : string option) =
  let text = with_open_in input_file In_channel.input_all in
  let ast, _ctx =
    Wax_parser.parse_from_string
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  let types, ast =
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wax.Typing.f d ast)
  in
  let wasm_ast_text =
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Conversion.To_wasm.module_ d types ast)
  in
  if validate then
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wasm.Validation.f d wasm_ast_text);
  let wasm_ast_binary = Wasm.Text_to_binary.module_ wasm_ast_text in
  with_open_out output_file (fun oc ->
      Wasm.Wasm_output.module_ ~out_channel:oc ?opt_source_map_file
        wasm_ast_binary)

let wat_to_wasm ~input_file ~output_file ~validate ~color ~fold_mode:_
    ~source_map_file:opt_source_map_file =
  let text = with_open_in input_file In_channel.input_all in
  let ast, _ctx =
    Wat_parser.parse_from_string
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  if validate then
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wasm.Validation.f d ast);
  let wasm_ast_binary = Wasm.Text_to_binary.module_ ast in
  with_open_out output_file (fun oc ->
      Wasm.Wasm_output.module_ ~out_channel:oc ?opt_source_map_file
        wasm_ast_binary)

let wasm_to_wasm ~input_file ~output_file ~validate:_validate ~color:_
    ~fold_mode:_ ~source_map_file:opt_source_map_file =
  let text = with_open_in input_file In_channel.input_all in
  let ast = Wasm.Wasm_parser.module_ text in
  (* if validate then Wasm.Validation.f ast; *)
  with_open_out output_file (fun oc ->
      Wasm.Wasm_output.module_ ~out_channel:oc ?opt_source_map_file ast)

let wasm_to_wat ~input_file ~output_file ~validate ~color ~fold_mode
    ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  let text = with_open_in input_file In_channel.input_all in
  let binary_ast = Wasm.Wasm_parser.module_ text in
  let text_ast = Wasm.Binary_to_text.module_ binary_ast in
  if validate then
    Utils.Diagnostic.run ~color ~source:None (fun d ->
        Wasm.Validation.f d text_ast);
  let trivia = Hashtbl.create 0 in
  output_wat ~fold_mode ~output_file ~color ~trivia text_ast

let wasm_to_wax ~input_file ~output_file ~validate ~color ~fold_mode:_
    ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  let text = with_open_in input_file In_channel.input_all in
  let binary_ast = Wasm.Wasm_parser.module_ text in
  let text_ast = Wasm.Binary_to_text.module_ binary_ast in
  if validate then
    Utils.Diagnostic.run ~color ~source:None (fun d ->
        Wasm.Validation.f d text_ast);
  let wax_ast =
    Utils.Diagnostic.run ~color ~source:None (fun d ->
        Conversion.From_wasm.module_ d text_ast)
  in
  if validate then
    ignore
      (Utils.Diagnostic.run ~color ~source:None (fun d ->
           Wax.Typing.f d wax_ast));
  with_open_out output_file (fun oc ->
      let print_wax f m =
        Utils.Printer.run f (fun p ->
            Wax.Output.module_ p ~color ~out_channel:oc m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wax wax_ast)

type format = Wat | Wasm | Wax

let string_of_format = function Wat -> "wat" | Wasm -> "wasm" | Wax -> "wax"

let format_of_string = function
  | "wat" -> Ok Wat
  | "wasm" -> Ok Wasm
  | "wax" -> Ok Wax
  | s -> Error (`Msg (Printf.sprintf "Unknown format: %s" s))

let string_of_color (c : Utils.Colors.flag) =
  match c with Never -> "never" | Always -> "always" | Auto -> "auto"

let color_of_string s : (Utils.Colors.flag, _) result =
  match s with
  | "never" -> Ok Never
  | "always" -> Ok Always
  | "auto" -> Ok Auto
  | s -> Error (`Msg (Printf.sprintf "Unknown color setting: %s" s))

let detect_format filename =
  if Filename.check_suffix filename ".wat" then Some Wat
  else if Filename.check_suffix filename ".wasm" then Some Wasm
  else if Filename.check_suffix filename ".wax" then Some Wax
  else None

let resolve_format file_opt format_opt ~default =
  match (file_opt, format_opt) with
  | _, Some fmt -> fmt
  | Some file, None -> (
      match detect_format file with Some fmt -> fmt | None -> default)
  | None, None -> default

let convert input_file output_file input_format_opt output_format_opt validate
    strict_validate color opt_source_map_file fold_mode =
  Wasm.Validation.validate_refs := strict_validate;
  let std file = Option.bind file (fun f -> if f = "-" then None else Some f) in
  let input_file = std input_file in
  let output_file = std output_file in
  let input_format = resolve_format input_file input_format_opt ~default:Wax in
  let output_format =
    resolve_format output_file output_format_opt ~default:Wasm
  in
  let convert =
    match (input_format, output_format) with
    | Wat, Wat -> wat_to_wat
    | Wat, Wax -> wat_to_wax
    | Wat, Wasm -> wat_to_wasm
    | Wax, Wat -> wax_to_wat
    | Wax, Wax -> wax_to_wax
    | Wax, Wasm -> wax_to_wasm
    | Wasm, Wat -> wasm_to_wat
    | Wasm, Wasm -> wasm_to_wasm
    | Wasm, Wax -> wasm_to_wax
  in
  if output_format = Wasm && output_file = None && Unix.isatty Unix.stdout then (
    Printf.eprintf "Binary output not allowed on terminal\n";
    exit 123);
  let color, with_pager =
    match output_file with
    | None -> (Utils.Colors.update_flag ~color, Utils.Pager.use)
    | Some _ -> (color, fun f -> f ())
  in
  with_pager @@ fun () ->
  convert ~input_file ~output_file ~validate ~color
    ~source_map_file:opt_source_map_file ~fold_mode

(* Define the input file argument (optional for stdin) *)
let input_file =
  let doc =
    "Input file (.wat, .wasm, or .wax). Reads from stdin if not specified."
  in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"INPUT" ~doc)

(* Define the --output/-o option *)
let output_file =
  let doc = "Output file. Writes to stdout if not specified." in
  Arg.(
    value & opt (some string) None & info [ "o"; "output" ] ~docv:"FILE" ~doc)

(* Define the --input-format option *)
let input_format =
  let doc =
    "Input format: wat (Wasm text format), wasm (Wasm binary format), or wax \
     (Wax language). If not specified, auto-detected from filename or defaults \
     to wax."
  in
  let format_conv =
    Arg.conv
      ( format_of_string,
        fun ppf fmt -> Format.fprintf ppf "%s" (string_of_format fmt) )
  in
  Arg.(
    value
    & opt (some format_conv) None
    & info [ "i"; "input-format" ] ~docv:"FORMAT" ~doc)

(* Define the --output-format option *)
let output_format =
  let doc =
    "Output format: wat (Wasm text format), wasm (Wasm binary format), or wax \
     (Wax language). If not specified, defaults to wasm."
  in
  let format_conv =
    Arg.conv
      ( format_of_string,
        fun ppf fmt -> Format.fprintf ppf "%s" (string_of_format fmt) )
  in
  Arg.(
    value
    & opt (some format_conv) None
    & info [ "f"; "format"; "output-format" ] ~docv:"FORMAT" ~doc)

(* Define the --validate option *)
let validate_flag =
  let doc =
    "Perform validation (type checking for Wax, well-formedness for Wasm \
     Text). Validation is disabled by default."
  in
  Arg.(value & flag & info [ "v"; "validate" ] ~doc)

(* Define the --strict-validate option *)
let strict_validate_flag =
  let doc =
    "Perform strict reference validation (for Wasm Text). This overrides the \
     default relaxed reference validation behavior."
  in
  Arg.(value & flag & info [ "s"; "strict-validate" ] ~doc)

(* Define the --color option *)
let color_option =
  let doc =
    "Color output: 'always', 'never', or 'auto' (default). 'auto' colors only \
     if output is a TTY."
  in
  let color_conv =
    Arg.conv
      (color_of_string, fun ppf c -> Format.fprintf ppf "%s" (string_of_color c))
  in
  Arg.(value & opt color_conv Auto & info [ "color" ] ~docv:"WHEN" ~doc)

(* Define the --source-map-file option *)
let source_map_file_option =
  let doc = "Generate a source map file." in
  Arg.(
    value
    & opt (some string) None
    & info [ "source-map-file" ] ~docv:"FILE" ~doc)

(* Define the --fold/--unfold option *)
let fold_mode_option =
  let doc = "Fold instructions into nested S-expressions." in
  let fold = (Fold, Arg.info [ "fold" ] ~doc) in
  let doc = "Unfold instructions into flat instruction lists." in
  let unfold = (Unfold, Arg.info [ "unfold" ] ~doc) in
  Arg.(value & vflag Auto [ fold; unfold ])

(* Combine into command *)
let convert_term =
  let+ input = input_file
  and+ output = output_file
  and+ in_fmt = input_format
  and+ out_fmt = output_format
  and+ validate = validate_flag
  and+ strict_validate = strict_validate_flag
  and+ color = color_option
  and+ source_map_file = source_map_file_option
  and+ fold_mode = fold_mode_option in
  convert input output in_fmt out_fmt validate strict_validate color
    source_map_file fold_mode

let convert_cmd =
  let doc = "Convert between WebAssembly formats (.wat, .wasm, .wax)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Convert between different WebAssembly formats: .wat (text), .wasm \
         (binary), and .wax.";
      `P "Supports reading from stdin and writing to stdout.";
      `P "Currently supported conversions:";
      `P "- Wat to Wat (formatting / round-trip)";
      `P "- Wat to Wax (decompilation / desugaring)";
      `P "- Wat to Wasm (binary output)";
      `P "- Wax to Wat (compilation / sugar removal)";
      `P "- Wax to Wax (formatting / checking)";
      `P "- Wax to Wasm (compilation to binary)";
      `P "- Wasm to Wasm (binary round-trip)";
      `P "- Wasm to Wat (disassembly)";
      `P "- Wasm to Wax (decompilation)";
      `P "Default conversion: wax -> wasm";
      `S Manpage.s_examples;
      `P "Convert file with auto-detected formats:";
      `Pre "  $(tname) input.wat -o output.wasm";
      `P "Read from stdin, write to stdout:";
      `Pre "  cat input.wat | $(tname) -i wat -f wasm > output.wasm";
      `P "Read from stdin, write to file:";
      `Pre "  cat input.wax | $(tname) -i wax -o output.wasm";
      `P "Explicit format specification:";
      `Pre "  $(tname) input -i wat -o output -f wasm";
      `S Manpage.s_options;
    ]
  in
  let info = Cmd.info "wax" ~doc ~man in
  Cmd.v info convert_term

let () = exit (Cmd.eval convert_cmd)
