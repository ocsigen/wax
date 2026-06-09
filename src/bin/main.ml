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

let output_wat ?(tail = []) ~fold_mode ~output_file ~color ~trivia ast =
  let ast =
    match fold_mode with
    | Auto -> ast
    | Fold -> Wasm.Folding.fold ast
    | Unfold -> Wasm.Folding.unfold ast
  in
  with_open_out output_file (fun oc ->
      let print_wat f m =
        Utils.Printer.run f (fun p ->
            Wasm.Output.module_ ~color ~out_channel:oc ~tail p ~trivia m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wat ast)

(* A formatter that discards everything, for the dry pass that records which
   locations the printer looks up. *)
let null_formatter () = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ())

(* Build the trivia for printing [ast], restricting the association to the
   locations the printer actually emits (collected by a dry pass). This keeps a
   comment from attaching to a node the printer skips — which would drop it.
   [retarget], when given, rewrites the comment delimiters between formats. *)
let wat_trivia ?retarget ~fold_mode ctx ast =
  let ast =
    match fold_mode with
    | Auto -> ast
    | Fold -> Wasm.Folding.fold ast
    | Unfold -> Wasm.Folding.unfold ast
  in
  let used = Hashtbl.create 256 in
  Utils.Printer.run (null_formatter ()) (fun p ->
      Wasm.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used ast);
  let trivia, tail = Utils.Trivia.associate ~only:used ctx in
  match retarget with
  | None -> (trivia, tail)
  | Some (src, dst) -> Utils.Trivia.retarget ~src ~dst trivia tail

let wax_trivia ?retarget ctx ast =
  let used = Hashtbl.create 256 in
  Utils.Printer.run (null_formatter ()) (fun p ->
      Wax.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used ast);
  let trivia, tail = Utils.Trivia.associate ~only:used ctx in
  match retarget with
  | None -> (trivia, tail)
  | Some (src, dst) -> Utils.Trivia.retarget ~src ~dst trivia tail

let wat_to_wat ~input_file ~output_file ~validate ~color ~output_color
    ~fold_mode ~source_map_file:opt_source_map_file =
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
  let trivia, tail = wat_trivia ~fold_mode ctx ast in
  output_wat ~fold_mode ~output_file ~color:output_color ~trivia ~tail ast

let wat_to_wax ~input_file ~output_file ~validate ~color ~output_color
    ~fold_mode:_ ~source_map_file:opt_source_map_file =
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
  let wax_ast =
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Conversion.From_wasm.module_ d ast)
  in
  let wax_ast =
    Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
        Wax.Typing.f d wax_ast)
    |> snd |> Wax.Typing.erase_types
  in
  (* The converted Wax nodes carry the source Wat locations, so the source
     trivia (keyed by those locations) maps onto them; rewrite the comment
     delimiters from Wat to Wax syntax. *)
  let trivia, tail =
    wax_trivia
      ~retarget:(Utils.Trivia.wat_syntax, Utils.Trivia.wax_syntax)
      ctx wax_ast
  in
  with_open_out output_file (fun oc ->
      let print_wax f m =
        Utils.Printer.run f (fun p ->
            Wax.Output.module_ p ~color:output_color ~out_channel:oc ~trivia
              ~tail m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wax wax_ast)

let wax_to_wat ~input_file ~output_file ~validate ~color ~output_color
    ~fold_mode ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  (* Ignored for non-wasm output *)
  let text = with_open_in input_file In_channel.input_all in
  let ast, ctx =
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
  (* Typing and conversion preserve the source Wax locations, so the source
     trivia (keyed by those locations) maps onto the converted Wasm nodes;
     rewrite the comment delimiters from Wax to Wat syntax. *)
  let trivia, tail =
    wat_trivia
      ~retarget:(Utils.Trivia.wax_syntax, Utils.Trivia.wat_syntax)
      ~fold_mode ctx wasm_ast
  in
  output_wat ~fold_mode ~output_file ~color:output_color ~trivia ~tail wasm_ast

let wax_to_wax ~input_file ~output_file ~validate ~color ~output_color
    ~fold_mode:_ ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  (* Ignored for non-wasm output *)
  let text = with_open_in input_file In_channel.input_all in
  let ast, ctx =
    Wax_parser.parse_from_string
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  if validate then
    ignore
      (Utils.Diagnostic.run ~color ~source:(Some text) (fun d ->
           Wax.Typing.f d ast));
  let trivia, tail = wax_trivia ctx ast in
  with_open_out output_file (fun oc ->
      let print_wax f m =
        Utils.Printer.run f (fun p ->
            Wax.Output.module_ p ~color:output_color ~out_channel:oc ~trivia
              ~tail m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wax ast)

let wax_to_wasm ~input_file ~output_file ~validate ~color ~output_color:_
    ~fold_mode:_ ~source_map_file:(opt_source_map_file : string option) =
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

let wat_to_wasm ~input_file ~output_file ~validate ~color ~output_color:_
    ~fold_mode:_ ~source_map_file:opt_source_map_file =
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

(* Parse a Wasm binary, reporting malformed input as a diagnostic (and exiting)
   through the standard diagnostics machinery. *)
let parse_wasm ~color ?filename text =
  Utils.Diagnostic.run ~color ~source:None (fun d ->
      Wasm.Wasm_parser.module_ d ?filename text)

let wasm_to_wasm ~input_file ~output_file ~validate:_validate ~color
    ~output_color:_ ~fold_mode:_ ~source_map_file:opt_source_map_file =
  let text = with_open_in input_file In_channel.input_all in
  let ast = parse_wasm ~color ?filename:input_file text in
  (* if validate then Wasm.Validation.f ast; *)
  with_open_out output_file (fun oc ->
      Wasm.Wasm_output.module_ ~out_channel:oc ?opt_source_map_file ast)

let wasm_to_wat ~input_file ~output_file ~validate ~color ~output_color
    ~fold_mode ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  let text = with_open_in input_file In_channel.input_all in
  let binary_ast = parse_wasm ~color ?filename:input_file text in
  let text_ast = Wasm.Binary_to_text.module_ binary_ast in
  if validate then
    Utils.Diagnostic.run ~color ~source:None (fun d ->
        Wasm.Validation.f d text_ast);
  let trivia = Hashtbl.create 0 in
  output_wat ~fold_mode ~output_file ~color:output_color ~trivia text_ast

let wasm_to_wax ~input_file ~output_file ~validate ~color ~output_color
    ~fold_mode:_ ~source_map_file:opt_source_map_file =
  let _ = opt_source_map_file in
  let text = with_open_in input_file In_channel.input_all in
  let binary_ast = parse_wasm ~color ?filename:input_file text in
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
            Wax.Output.module_ p ~color:output_color ~out_channel:oc
              ~trivia:(Hashtbl.create 0) m)
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
  (* [update_flag] resolves color for the wat/wax output only (against the real
     stdout, before the pager redirects it). Errors keep the original flag, so
     [Diagnostic] resolves them against stderr. *)
  let output_color, with_pager =
    match output_file with
    | None -> (Utils.Colors.update_flag ~color, Utils.Pager.use)
    | Some _ -> (color, fun f -> f ())
  in
  with_pager @@ fun () ->
  convert ~input_file ~output_file ~validate ~color ~output_color
    ~source_map_file:opt_source_map_file ~fold_mode

(* Format files: re-print each in its own format (wat -> wat, wax -> wax, wasm
   -> wasm), detected from the extension unless [format_opt] forces one. With
   [--inplace] the result is written back to each file; with [--check] nothing
   is written and files that are not already formatted are listed (a non-zero
   exit status reports this); otherwise exactly one file is formatted to stdout.
   [validate] additionally type-checks (Wax) / well-formedness-checks (Wasm). *)
let format inplace check format_opt validate color fold_mode files =
  if inplace && check then (
    Printf.eprintf "--inplace and --check cannot be combined.\n";
    exit 123);
  if (not inplace) && (not check) && List.length files <> 1 then (
    Printf.eprintf
      "Exactly one input file must be specified without --inplace or --check.\n";
    exit 123);
  let read path = In_channel.with_open_bin path In_channel.input_all in
  (* Returns false on an error or, in check mode, a file that needs formatting. *)
  let format_one file =
    match
      match format_opt with Some _ -> format_opt | None -> detect_format file
    with
    | None ->
        Printf.eprintf
          "%s: cannot detect format (expected .wat, .wax or .wasm)\n" file;
        false
    | Some fmt ->
        let same_format =
          match fmt with
          | Wat -> wat_to_wat
          | Wax -> wax_to_wax
          | Wasm -> wasm_to_wasm
        in
        let run ~output_file ~output_color =
          same_format ~input_file:(Some file) ~output_file ~validate ~color
            ~output_color ~source_map_file:None ~fold_mode
        in
        if check then
          (* Format into a temporary file and compare with the original, so the
             check matches exactly what --inplace would write. *)
          let tmp = Filename.temp_file "wax-format-" "" in
          Fun.protect
            ~finally:(fun () -> try Sys.remove tmp with Sys_error _ -> ())
            (fun () ->
              run ~output_file:(Some tmp) ~output_color:Utils.Colors.Never;
              String.equal (read file) (read tmp)
              ||
              (print_endline file;
               false))
        else if (not inplace) && fmt = Wasm && Unix.isatty Unix.stdout then (
          Printf.eprintf "Binary output not allowed on terminal\n";
          false)
        else
          (* Writing back into a source file must never embed ANSI colors;
             when formatting to stdout, resolve color as usual. *)
          let output_color =
            if inplace then Utils.Colors.Never
            else Utils.Colors.update_flag ~color
          in
          run ~output_file:(if inplace then Some file else None) ~output_color;
          true
  in
  if not (List.fold_left (fun ok file -> format_one file && ok) true files) then
    exit 123

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

(* Define the --inplace/-i flag (format command) *)
let inplace_flag =
  let doc = "Write the formatted output back to each input file." in
  Arg.(value & flag & info [ "i"; "inplace" ] ~doc)

(* Define the --check/-c flag (format command) *)
let check_flag =
  let doc =
    "Do not write anything; list the files that are not already formatted and \
     exit with a non-zero status if any are found."
  in
  Arg.(value & flag & info [ "c"; "check" ] ~doc)

(* Define the format of the input files (format command). [-i] is taken by
   --inplace, so the format override uses -f here. *)
let format_input =
  let doc =
    "Treat all input files as this format (wat, wasm or wax), overriding the \
     detection from each file's extension."
  in
  let format_conv =
    Arg.conv
      ( format_of_string,
        fun ppf fmt -> Format.fprintf ppf "%s" (string_of_format fmt) )
  in
  Arg.(
    value
    & opt (some format_conv) None
    & info [ "f"; "format"; "input-format" ] ~docv:"FORMAT" ~doc)

(* Define the input files of the format command *)
let format_files =
  let doc = "Input files (.wat, .wasm or .wax) to format." in
  Arg.(non_empty & pos_all string [] & info [] ~docv:"FILE" ~doc)

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

let format_term =
  let+ inplace = inplace_flag
  and+ check = check_flag
  and+ format_opt = format_input
  and+ validate = validate_flag
  and+ color = color_option
  and+ fold_mode = fold_mode_option
  and+ files = format_files in
  format inplace check format_opt validate color fold_mode files

let format_cmd =
  let doc = "Format WebAssembly source files (.wat, .wasm, .wax)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Reformat each input file in its own format (Wat to Wat, Wax to Wax, \
         Wasm to Wasm).";
      `P
        "With --inplace, the formatted output is written back to each file. \
         With --check, nothing is written and files that are not already \
         formatted are listed (with a non-zero exit status). Otherwise exactly \
         one file must be given and its formatted output is written to stdout.";
      `P
        "The format of each file is detected from its extension unless \
         --format forces one.";
      `S Manpage.s_examples;
      `P "Format a single file to stdout:";
      `Pre "  $(mname) $(tname) input.wat";
      `P "Reformat several files in place:";
      `Pre "  $(mname) $(tname) -i a.wax b.wax c.wax";
      `P "Check formatting in CI (non-zero exit if any file differs):";
      `Pre "  $(mname) $(tname) --check src/*.wax";
      `S Manpage.s_options;
    ]
  in
  Cmd.v (Cmd.info "format" ~doc ~man) format_term

let convert_cmd =
  let doc = "Convert between WebAssembly formats (the default command)" in
  Cmd.v (Cmd.info "convert" ~doc) convert_term

let main_cmd =
  let doc = "Convert between WebAssembly formats (.wat, .wasm, .wax)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "By default, convert between different WebAssembly formats: .wat \
         (text), .wasm (binary), and .wax. The $(b,format) command reformats \
         files in place.";
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
      `P "Format files in place:";
      `Pre "  $(tname) format -i a.wax b.wax";
      `S Manpage.s_options;
    ]
  in
  Cmd.group (Cmd.info "wax" ~doc ~man) ~default:convert_term
    [ convert_cmd; format_cmd ]

(* cmdliner reads the first token as a subcommand name and, even with a default
   command, errors on an unrecognised one rather than falling through. So that
   the bare [wax <file>] form keeps working (it is the common case, and the one
   every test uses), rewrite the argv as js_of_ocaml does: a leading token that
   is neither an option nor a bare command word (e.g. a filename, which carries
   a [.] extension) is dispatched to the default [convert] command explicitly. *)
let () =
  let argv =
    (* A lone "-" is the stdin positional, not an option, so it must reach the
       default command rather than being read as a subcommand name. *)
    let like_arg x = String.length x > 1 && Char.equal x.[0] '-' in
    let like_command x =
      String.length x > 0
      && (not (Char.equal x.[0] '-'))
      && String.for_all
           (function 'a' .. 'z' | 'A' .. 'Z' | '-' -> true | _ -> false)
           x
    in
    match Array.to_list Sys.argv with
    | exe :: first :: rest when not (like_command first || like_arg first) ->
        Array.of_list (exe :: Cmd.name convert_cmd :: first :: rest)
    | _ -> Sys.argv
  in
  exit (Cmd.eval ~argv main_cmd)
