open Cmdliner
open Term.Syntax

(*** Parsers and I/O helpers ***)

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

let with_open_in ~color file f =
  match file with
  | Some file -> (
      try In_channel.with_open_bin file f
      with Sys_error msg ->
        Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
          ~source:None (fun d ->
            Wax_utils.Diagnostic.report d ~location:Wax_utils.Ast.dummy_loc
              ~severity:Wax_utils.Diagnostic.Error
              ~message:(Wax_utils.Message.text msg)
              ();
            Wax_utils.Diagnostic.abort ()))
  | None -> f stdin

let with_open_out ~color file f =
  match file with
  | Some file -> (
      try Out_channel.with_open_bin file f
      with Sys_error msg ->
        Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
          ~source:None (fun d ->
            Wax_utils.Diagnostic.report d ~location:Wax_utils.Ast.dummy_loc
              ~severity:Wax_utils.Diagnostic.Error
              ~message:(Wax_utils.Message.text msg)
              ();
            Wax_utils.Diagnostic.abort ()))
  | None -> f stdout

(* Apply the [-D]/[--define] bindings to a freshly-parsed source module,
   splicing out and simplifying conditional annotations. With no bindings this
   is the identity, so the common case is untouched. Specialization runs before
   validation and conversion, so the rest of the pipeline sees the specialized
   module. The comments inside a removed branch are dropped from the parse
   context [ctx] (when one is given — text output only), so they do not
   re-attach to a surviving node. *)
let specialize_wax ?ctx ~color ~text defines ast =
  if Wax_wasm.Cond_specialize.is_empty defines then ast
  else
    let ast, dropped =
      Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
        ~source:(Some text) (fun d ->
          Wax_lang.Cond_specialize.module_ d defines ast)
    in
    Option.iter (fun ctx -> Wax_utils.Trivia.drop_in_ranges ctx dropped) ctx;
    ast

let specialize_wat ?ctx ~color ~text defines ast =
  if Wax_wasm.Cond_specialize.is_empty defines then ast
  else
    let ast, dropped =
      Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
        ~source:(Some text) (fun d ->
          Wax_wasm.Cond_specialize.module_ d defines ast)
    in
    Option.iter (fun ctx -> Wax_utils.Trivia.drop_in_ranges ctx dropped) ctx;
    ast

(* Lower a text module to the binary format. A leftover conditional annotation
   cannot be represented in binary; report it as a located diagnostic (rather
   than an uncaught exception) and suggest resolving it. *)
let to_binary ~color ~source ast =
  Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme ~source
    (fun d ->
      try Wax_wasm.Text_to_binary.module_ ast with
      | Wax_wasm.Text_to_binary.Conditional_in_binary location ->
          Wax_utils.Diagnostic.report d ~location ~severity:Error
            ~message:
              (Wax_utils.Message.text
                 "Conditional annotations cannot be emitted to the WebAssembly \
                  binary format.")
            ~hint:
              (Wax_utils.Message.text
                 "Resolve the conditionals with -D/--define, or convert to a \
                  text format (wat or wax).")
            ();
          Wax_utils.Diagnostic.abort ()
      | Wax_wasm.Text_to_binary.Unresolved_reference (location, message) ->
          Wax_utils.Diagnostic.report d ~location ~severity:Error
            ~message:(Wax_utils.Message.text message)
            ();
          Wax_utils.Diagnostic.abort ())

(* Expand the [@string]/[@char] annotations of a text module into core wasm
   ([array.new_fixed] / [i32.const]). A leftover conditional annotation has no
   core-wasm form; report it as a located diagnostic (rather than an uncaught
   exception) and suggest resolving it. *)
let desugar_wat ~color ~source ast =
  Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme ~source
    (fun d ->
      try Wax_wasm.Desugar.module_ ast
      with Wax_wasm.Desugar.Conditional_remains location ->
        Wax_utils.Diagnostic.report d ~location ~severity:Error
          ~message:
            (Wax_utils.Message.text
               "A conditional annotation cannot be desugared to plain \
                WebAssembly text.")
          ~hint:
            (Wax_utils.Message.text "Resolve the conditionals with -D/--define.")
          ();
        Wax_utils.Diagnostic.abort ())

type fold_mode = Auto | Fold | Unfold

(* Apply the requested folding to a WAT module. Folding runs on input that is
   not validated first (unvalidated wat->wat, trusted wasm->wat), so [fold]
   reports malformed indices as diagnostics; give it a context. Unfolding is a
   pure structural rewrite that cannot fail. *)
let fold_module ~fold_mode ~color ~source ast =
  match fold_mode with
  | Auto -> ast
  | Fold ->
      Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
        ~source (fun d -> Wax_wasm.Folding.fold d ast)
  | Unfold -> Wax_wasm.Folding.unfold ast

let output_wat ?(tail = []) ~output_file ~color ~trivia ast =
  with_open_out ~color output_file (fun oc ->
      let print_wat f m =
        Wax_utils.Printer.run f (fun p ->
            Wax_wasm.Output.module_ ~color ~out_channel:oc ~tail p ~trivia m)
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
let wat_trivia ?retarget ctx ast =
  let used = Hashtbl.create 256 in
  Wax_utils.Printer.run (null_formatter ()) (fun p ->
      Wax_wasm.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used ast);
  let trivia, tail = Wax_utils.Trivia.associate ~only:used ctx in
  match retarget with
  | None -> (trivia, tail)
  | Some (src, dst) -> Wax_utils.Trivia.retarget ~src ~dst trivia tail

let wax_trivia ?retarget ctx ast =
  let used = Hashtbl.create 256 in
  (* Width is irrelevant to the dry pass: it only records which locations the
     printer looks up, and the traversal is the same at any width. *)
  Wax_utils.Printer.run (null_formatter ()) (fun p ->
      Wax_lang.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used ast);
  let trivia, tail = Wax_utils.Trivia.associate ~only:used ctx in
  match retarget with
  | None -> (trivia, tail)
  | Some (src, dst) -> Wax_utils.Trivia.retarget ~src ~dst trivia tail

(* Process exit codes (see docs/src/cli.md, "Exit status"):
     0   success
     123 a usage error (an invalid flag combination), or a [format --check]
         run that found files needing formatting
     124 a command-line parse error (from cmdliner: unknown flag, bad value)
     125 an internal error / uncaught exception (from cmdliner)
     128 the input was rejected by a diagnostic: a parse, validation or type
         error, or a malformed wasm binary (also the status of a [check] run
         that found any problem)
   Rejected input exits 128 wherever it is detected: [parsing.ml] (syntax),
   [Diagnostic.output_errors] (validation/type), and the [check] aggregate
   below. [usage_error] owns the 123 usage path. Keep in sync with
   fuzz/lib.sh's classify_wax. *)
let usage_error msg =
  Printf.eprintf "%s\n" msg;
  exit 123

(*** Conversion pipelines ***)

let wat_to_wat ~input_file ~output_file ~validate ~warn_unused ~color
    ~output_color ~fold_mode ~defines ~desugar ~source_map:_ =
  let text = with_open_in ~color input_file In_channel.input_all in
  let ast, ctx =
    Wat_parser.parse_from_string ~color
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  let ast = specialize_wat ~ctx ~color ~text defines ast in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:(Some text) (fun d -> Wax_wasm.Validation.f ~warn_unused d ast);
  let ast =
    if desugar then desugar_wat ~color ~source:(Some text) ast else ast
  in
  let ast = fold_module ~fold_mode ~color ~source:(Some text) ast in
  let trivia, tail = wat_trivia ctx ast in
  output_wat ~output_file ~color:output_color ~trivia ~tail ast

let wat_to_wax ~input_file ~output_file ~validate ~warn_unused ~color
    ~output_color ~fold_mode:_ ~defines ~desugar:_ ~source_map:_ =
  let text = with_open_in ~color input_file In_channel.input_all in
  let ast, ctx =
    Wat_parser.parse_from_string ~color
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  let ast = specialize_wat ~ctx ~color ~text defines ast in
  (* Share one feature set between validation, which records the gated features
     the module exercises, and the conversion, which stamps a [#![feature]]
     attribute for each so the output recompiles standalone. *)
  let features = Wax_utils.Feature.default () in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:(Some text) (fun d ->
        Wax_wasm.Validation.f ~warn_unused ~features d ast);
  let wax_ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d ->
        Wax_conversion.From_wasm.module_ ~features d ast)
  in
  let wax_ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d -> Wax_lang.Typing.f ~simplify:true d wax_ast)
    |> snd |> Wax_lang.Typing.erase_types
  in
  (* The converted Wax nodes carry the source Wat locations, so the source
     trivia (keyed by those locations) maps onto them; rewrite the comment
     delimiters from Wat to Wax syntax. *)
  let trivia, tail =
    wax_trivia
      ~retarget:(Wax_utils.Trivia.wat_syntax, Wax_utils.Trivia.wax_syntax)
      ctx wax_ast
  in
  with_open_out ~color output_file (fun oc ->
      let print_wax f m =
        Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
            Wax_lang.Output.module_ p ~color:output_color ~out_channel:oc
              ~trivia ~tail m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wax wax_ast)

let wax_to_wat ~input_file ~output_file ~validate ~warn_unused ~color
    ~output_color ~fold_mode ~defines ~desugar ~source_map:_ =
  let text = with_open_in ~color input_file In_channel.input_all in
  let ast, ctx =
    Wax_parser.parse_from_string ~color
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  let ast = specialize_wax ~ctx ~color ~text defines ast in
  let types, ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d -> Wax_lang.Typing.f ~warn_unused d ast)
  in
  let wasm_ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d -> Wax_conversion.To_wasm.module_ d types ast)
  in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:(Some text) (fun d ->
        (* Unused locals are reported against the Wax source by [Wax_lang.Typing.f]
           above; do not repeat them against the compiled Wasm. *)
        Wax_wasm.Validation.f ~warn_unused:false d wasm_ast);
  let wasm_ast =
    if desugar then desugar_wat ~color ~source:(Some text) wasm_ast
    else wasm_ast
  in
  let wasm_ast = fold_module ~fold_mode ~color ~source:(Some text) wasm_ast in
  (* Typing and conversion preserve the source Wax locations, so the source
     trivia (keyed by those locations) maps onto the converted Wasm nodes;
     rewrite the comment delimiters from Wax to Wat syntax. *)
  let trivia, tail =
    wat_trivia
      ~retarget:(Wax_utils.Trivia.wax_syntax, Wax_utils.Trivia.wat_syntax)
      ctx wasm_ast
  in
  output_wat ~output_file ~color:output_color ~trivia ~tail wasm_ast

let wax_to_wax ~input_file ~output_file ~validate ~warn_unused ~color
    ~output_color ~fold_mode:_ ~defines ~desugar:_ ~source_map:_ =
  let text = with_open_in ~color input_file In_channel.input_all in
  let ast, ctx =
    Wax_parser.parse_from_string ~color
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  let ast = specialize_wax ~ctx ~color ~text defines ast in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d -> Wax_lang.Typing.check ~warn_unused d ast);
  let trivia, tail = wax_trivia ctx ast in
  with_open_out ~color output_file (fun oc ->
      let print_wax f m =
        Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
            Wax_lang.Output.module_ p ~color:output_color ~out_channel:oc
              ~trivia ~tail m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wax ast)

let wax_to_wasm ~input_file ~output_file ~validate ~warn_unused ~color
    ~output_color:_ ~fold_mode:_ ~defines ~desugar:_ ~source_map =
  let text = with_open_in ~color input_file In_channel.input_all in
  let ast, _ctx =
    Wax_parser.parse_from_string ~color
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  let ast = specialize_wax ~color ~text defines ast in
  (* Share one feature set between typing, which enables the features the
     module declares with [#![feature]] attributes, and the binary emitter,
     whose compact-import-section encoding is gated on it. *)
  let features = Wax_utils.Feature.default () in
  let types, ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d ->
        Wax_lang.Typing.f ~warn_unused ~features d ast)
  in
  let wasm_ast_text =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:(Some text) (fun d -> Wax_conversion.To_wasm.module_ d types ast)
  in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:(Some text) (fun d ->
        (* Unused locals are reported against the Wax source by [Wax_lang.Typing.f]
           above; do not repeat them against the compiled Wasm. *)
        Wax_wasm.Validation.f ~warn_unused:false d wasm_ast_text);
  let wasm_ast_binary = to_binary ~color ~source:(Some text) wasm_ast_text in
  with_open_out ~color output_file (fun oc ->
      Wax_wasm.Wasm_output.module_ ~out_channel:oc ?output_file ~source_map
        ~features wasm_ast_binary)

let wat_to_wasm ~input_file ~output_file ~validate ~warn_unused ~color
    ~output_color:_ ~fold_mode:_ ~defines ~desugar:_ ~source_map =
  let text = with_open_in ~color input_file In_channel.input_all in
  let ast, _ctx =
    Wat_parser.parse_from_string ~color
      ~filename:(Option.value ~default:"-" input_file)
      text
  in
  let ast = specialize_wat ~color ~text defines ast in
  (* Declare any function referenced by ref.func only inside a body, so the
     emitted binary passes strict reference validation. *)
  let ast = Wax_wasm.Declare_refs.module_ ast in
  (* Share one feature set between validation, which enables the features the
     module declares with [(@feature)] annotations, and the binary emitter,
     whose compact-import-section encoding is gated on it. *)
  let features = Wax_utils.Feature.default () in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:(Some text) (fun d ->
        Wax_wasm.Validation.f ~warn_unused ~features d ast);
  let wasm_ast_binary = to_binary ~color ~source:(Some text) ast in
  with_open_out ~color output_file (fun oc ->
      Wax_wasm.Wasm_output.module_ ~out_channel:oc ?output_file ~source_map
        ~features wasm_ast_binary)

(* Parse a Wasm binary, reporting malformed input as a diagnostic (and exiting)
   through the standard diagnostics machinery. *)
let parse_wasm ~color ?features ?filename text =
  Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
    ~source:None (fun d ->
      Wax_wasm.Wasm_parser.module_ d ?features ?filename text)

let wasm_to_wasm ~input_file ~output_file ~validate:_validate ~warn_unused:_
    ~color ~output_color:_ ~fold_mode:_ ~defines:_ ~desugar:_ ~source_map =
  let text = with_open_in ~color input_file In_channel.input_all in
  let ast = parse_wasm ~color ?filename:input_file text in
  (* if validate then Wax_wasm.Validation.f ast; *)
  with_open_out ~color output_file (fun oc ->
      Wax_wasm.Wasm_output.module_ ~out_channel:oc ?output_file ~source_map ast)

let wasm_to_wat ~input_file ~output_file ~validate ~warn_unused ~color
    ~output_color ~fold_mode ~defines:_ ~desugar:_ ~source_map:_ =
  let text = with_open_in ~color input_file In_channel.input_all in
  (* The decoder records the gated features the binary exercises; emit each as
     a [(@feature)] annotation so the text output is self-describing. *)
  let features = Wax_utils.Feature.default () in
  let binary_ast = parse_wasm ~color ~features ?filename:input_file text in
  let text_ast = Wax_wasm.Binary_to_text.module_ ~features binary_ast in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:None (fun d -> Wax_wasm.Validation.f ~warn_unused d text_ast);
  let text_ast = fold_module ~fold_mode ~color ~source:None text_ast in
  let trivia = Hashtbl.create 0 in
  output_wat ~output_file ~color:output_color ~trivia text_ast

let wasm_to_wax ~input_file ~output_file ~validate ~warn_unused ~color
    ~output_color ~fold_mode:_ ~defines:_ ~desugar:_ ~source_map:_ =
  let text = with_open_in ~color input_file In_channel.input_all in
  (* The decoder records the gated features the binary exercises; each becomes
     a [(@feature)] annotation, converted below to a [#![feature]] attribute,
     so the output recompiles standalone. *)
  let features = Wax_utils.Feature.default () in
  let binary_ast = parse_wasm ~color ~features ?filename:input_file text in
  let text_ast = Wax_wasm.Binary_to_text.module_ ~features binary_ast in
  if validate then
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:None (fun d -> Wax_wasm.Validation.f ~warn_unused d text_ast);
  let wax_ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:None (fun d -> Wax_conversion.From_wasm.module_ d text_ast)
  in
  (* Type the converted module to drop casts the precise types make redundant
     and tighten [&?extern]/[&?any] casts, as the WAT-to-Wax path does. *)
  let wax_ast =
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wax_theme
      ~source:None (fun d -> Wax_lang.Typing.f ~simplify:true d wax_ast)
    |> snd |> Wax_lang.Typing.erase_types
  in
  with_open_out ~color output_file (fun oc ->
      let print_wax f m =
        Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
            Wax_lang.Output.module_ p ~color:output_color ~out_channel:oc
              ~trivia:(Hashtbl.create 0) m)
      in
      let fmt = Format.formatter_of_out_channel oc in
      Format.fprintf fmt "%a@." print_wax wax_ast)

(*** Formats, options, and policy ***)

type format = Wat | Wasm | Wax

let string_of_format = function Wat -> "wat" | Wasm -> "wasm" | Wax -> "wax"

let format_of_string = function
  | "wat" -> Ok Wat
  | "wasm" -> Ok Wasm
  | "wax" -> Ok Wax
  | s -> Error (`Msg (Printf.sprintf "Unknown format: %s" s))

let string_of_color (c : Wax_utils.Colors.flag) =
  match c with Never -> "never" | Always -> "always" | Auto -> "auto"

let color_of_string s : (Wax_utils.Colors.flag, _) result =
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

(* Warning specs from the [WAX_WARN] environment variable, a list of
   [NAME=LEVEL] specs separated by commas or whitespace (e.g.
   [WAX_WARN="correctness=hidden unused-local=error"]). They seed the policy
   before the command-line [-W] specs, which therefore refine them: unlike
   cmdliner's built-in env fallback (dropped entirely when the flag is given),
   the environment defaults still apply when [-W] is passed. A malformed or
   unknown entry is reported on stderr and skipped, so a stray value never
   aborts the run. *)
let wax_warn_env = "WAX_WARN"

let env_warn_specs () =
  match Sys.getenv_opt wax_warn_env with
  | None | Some "" -> []
  | Some s ->
      String.split_on_char ',' s
      |> List.concat_map (String.split_on_char ' ')
      |> List.concat_map (String.split_on_char '\t')
      |> List.filter (fun s -> s <> "")
      |> List.filter_map (fun spec ->
          match Wax_utils.Warning.parse_spec spec with
          | Ok (name, level) -> (
              match
                Wax_utils.Warning.set Wax_utils.Warning.default_policy name
                  level
              with
              | Ok _ -> Some (name, level)
              | Error e ->
                  prerr_endline (Printf.sprintf "wax: %s: %s" wax_warn_env e);
                  None)
          | Error e ->
              prerr_endline (Printf.sprintf "wax: %s: %s" wax_warn_env e);
              None)

(* Build a warning policy: the defaults, then the [WAX_WARN] environment specs,
   then the [-W] command-line specs — each left to right, so later settings win
   (command line over environment over defaults). The command-line names are
   already validated by [warn_option]'s converter. *)
let build_policy specs =
  List.fold_left
    (fun policy (name, level) ->
      match Wax_utils.Warning.set policy name level with
      | Ok policy -> policy
      | Error _ -> policy)
    Wax_utils.Warning.default_policy
    (env_warn_specs () @ specs)

(* Documents [WAX_WARN] in the ENVIRONMENT section of each command's help. The
   variable is read directly by [env_warn_specs] (not via cmdliner's [~env]
   fallback, which would be dropped when [-W] is given). *)
let warn_env_info =
  Cmd.Env.info wax_warn_env
    ~doc:
      "Default warning levels applied before any $(b,-W) option, as a list of \
       $(i,NAME=LEVEL) specs separated by commas or whitespace (e.g. \
       $(b,correctness=hidden unused-local=error))."

(*** Command implementations ***)

let convert input_file output_file input_format_opt output_format_opt validate
    strict_validate color source_map fold_mode desugar defines warnings features
    debug error_format =
  Wax_utils.Diagnostic.set_policy (build_policy warnings);
  Wax_utils.Diagnostic.set_format error_format;
  Wax_utils.Feature.set_config features;
  Wax_utils.Debug.enable debug;
  let defines = Wax_wasm.Cond_specialize.of_list defines in
  let std file = Option.bind file (fun f -> if f = "-" then None else Some f) in
  let input_file = std input_file in
  let output_file = std output_file in
  let input_format = resolve_format input_file input_format_opt ~default:Wax in
  (* Reference validation is always strict for a Wasm binary input: a binary has
     no way to leave a reference unresolved, so a relaxed check would only hide
     real errors. Text inputs honour the [--strict-validate] flag. *)
  Wax_wasm.Validation.validate_refs := strict_validate || input_format = Wasm;
  let output_format =
    resolve_format output_file output_format_opt ~default:Wax
  in
  (* A source map relates a wasm binary's byte offsets to source positions, so
     it is only meaningful for wasm output. Reject it for text output rather
     than silently discarding it (the text emitters ignore it). *)
  if source_map && output_format <> Wasm then
    usage_error "--source-map is only supported for wasm output";
  if source_map && output_file = None then
    usage_error "--source-map requires an output file";
  (* Desugaring rewrites Wax-specific annotations into core wasm *text*; it is
     meaningful only for wat output (wasm output is already desugared, and wax
     output is the sugar). *)
  if desugar && output_format <> Wat then
    usage_error "--desugar is only supported for wat output";
  (* [--validate] enables unused-local reporting; it is not implied by the
     forced validation below. *)
  let warn_unused = validate in
  (* A text input (Wax/Wat) is validated before it is transformed to a different
     format: the conversion and lowering passes trust that their input is
     well-formed, so a malformed module would otherwise reach them and misbehave.
     A same-format transform (wat->wat, wax->wax) only re-prints, so it is not
     validated by default; nor is a Wasm binary (trusted, from a producer that
     already validated it). [--validate] forces validation in every case. *)
  let validate =
    validate || (input_format <> Wasm && input_format <> output_format)
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
  if output_format = Wasm && output_file = None && Unix.isatty Unix.stdout then
    usage_error "Binary output not allowed on terminal";
  (* [update_flag] resolves color for the wat/wax output only (against the real
     stdout, before the pager redirects it). Errors keep the original flag, so
     [Diagnostic] resolves them against stderr. *)
  let output_color, with_pager =
    match output_file with
    | None -> (Wax_utils.Colors.update_flag ~color, Wax_utils.Pager.use)
    | Some _ -> (color, fun f -> f ())
  in
  with_pager @@ fun () ->
  convert ~input_file ~output_file ~validate ~warn_unused ~color ~output_color
    ~source_map ~fold_mode ~defines ~desugar

(* Format files: re-print each in its own format (wat -> wat, wax -> wax, wasm
   -> wasm), detected from the extension unless [format_opt] forces one. With
   [--inplace] the result is written back to each file; with [--check] nothing
   is written and files that are not already formatted are listed (a non-zero
   exit status reports this); otherwise exactly one file is formatted to stdout.
   Formatting never validates: it only re-prints. *)
let format inplace check format_opt color fold_mode warnings debug error_format
    files =
  Wax_utils.Diagnostic.set_policy (build_policy warnings);
  Wax_utils.Diagnostic.set_format error_format;
  Wax_utils.Debug.enable debug;
  if inplace && check then
    usage_error "--inplace and --check cannot be combined.";
  let same_format_of = function
    | Wat -> wat_to_wat
    | Wax -> wax_to_wax
    | Wasm -> wasm_to_wasm
  in
  (* No file: format standard input to standard output. This is the interface an
     editor formatter or a shell pipe uses. The format cannot be detected (there
     is no filename), so --format is required, and --inplace / --check act on
     named files and so are rejected here. *)
  if files = [] then (
    if inplace || check then
      usage_error "--inplace and --check require one or more input files.";
    match format_opt with
    | None ->
        usage_error
          "A format is required when reading from standard input; use --format."
    | Some Wasm when Unix.isatty Unix.stdout ->
        Printf.eprintf "Binary output not allowed on terminal\n";
        exit 123
    | Some fmt ->
        (same_format_of fmt) ~input_file:None ~output_file:None ~validate:false
          ~warn_unused:false ~color
          ~output_color:(Wax_utils.Colors.update_flag ~color)
          ~source_map:false ~fold_mode ~desugar:false
          ~defines:(Wax_wasm.Cond_specialize.of_list []))
  else begin
    if (not inplace) && (not check) && List.length files <> 1 then
      usage_error
        "Exactly one input file must be specified without --inplace or --check.";
    let read path = In_channel.with_open_bin path In_channel.input_all in
    (* Returns false on an error or, in check mode, a file that needs formatting. *)
    let format_one file =
      match
        match format_opt with
        | Some _ -> format_opt
        | None -> detect_format file
      with
      | None ->
          Printf.eprintf
            "%s: cannot detect format (expected .wat, .wax or .wasm)\n" file;
          false
      | Some fmt ->
          let same_format = same_format_of fmt in
          let run ~output_file ~output_color =
            same_format ~input_file:(Some file) ~output_file ~validate:false
              ~warn_unused:false ~color ~output_color ~source_map:false
              ~fold_mode ~desugar:false
              ~defines:(Wax_wasm.Cond_specialize.of_list [])
          in
          if check then
            (* Format into a temporary file and compare with the original, so the
             check matches exactly what --inplace would write. *)
            let tmp = Filename.temp_file "wax-format-" "" in
            Fun.protect
              ~finally:(fun () -> try Sys.remove tmp with Sys_error _ -> ())
              (fun () ->
                run ~output_file:(Some tmp) ~output_color:Wax_utils.Colors.Never;
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
              if inplace then Wax_utils.Colors.Never
              else Wax_utils.Colors.update_flag ~color
            in
            run ~output_file:(if inplace then Some file else None) ~output_color;
            true
    in
    if not (List.fold_left (fun ok file -> format_one file && ok) true files)
    then exit 123
  end

(* Check files: parse and validate each (type-check Wax, well-formedness Wasm)
   without producing any output, reporting diagnostics and exiting with a
   non-zero status if any file fails. [format_opt] forces the format; otherwise
   it is detected from the extension. *)
let check format_opt strict color warnings features debug error_format defines
    all_errors files =
  Wax_wasm.Validation.validate_refs := strict;
  let policy = build_policy warnings in
  Wax_utils.Diagnostic.set_policy policy;
  Wax_utils.Diagnostic.set_format error_format;
  Wax_utils.Feature.set_config features;
  Wax_utils.Debug.enable debug;
  (* -D bindings specialize the conditionals before validation, exactly as in
     [convert]; a partial set leaves the remaining conditionals for the
     path-sensitive check to explore. *)
  let defines = Wax_wasm.Cond_specialize.of_list defines in
  let check_one file =
    match
      match format_opt with Some _ -> format_opt | None -> detect_format file
    with
    | None ->
        Printf.eprintf
          "%s: cannot detect format (expected .wat, .wax or .wasm)\n" file;
        false
    | Some fmt -> (
        (* A Wasm binary is always checked strictly (see [convert]); text inputs
           honour [--strict-validate]. *)
        Wax_wasm.Validation.validate_refs := strict || fmt = Wasm;
        let text = with_open_in ~color (Some file) In_channel.input_all in
        let source = match fmt with Wasm -> None | Wat | Wax -> Some text in
        (* Collect errors without printing or exiting, so every file is checked
           and all its errors are reported, then re-report them below. *)
        let d = Wax_utils.Diagnostic.collector ~source:text () in
        (* Feed every recovered syntax error into [d] and put it into recovery
           mode when there are any, so the downstream type-check / validation
           suppresses the cascades from constructs dropped at a sync boundary
           (see [Diagnostic.set_recovery]). Shared by the Wax and Wat
           [--all-errors] arms. *)
        let seed_recovery syntax_errors =
          List.iter
            (fun (e : Wax_wasm.Parsing.syntax_error) ->
              Wax_utils.Diagnostic.report d ~location:e.location
                ~severity:Wax_utils.Diagnostic.Error ~related:e.related
                ~message:e.message ())
            syntax_errors;
          Wax_utils.Diagnostic.set_recovery d (syntax_errors <> [])
        in
        (try
           match fmt with
           | Wax when all_errors -> (
               (* Panic-mode recovery: collect every syntax error into [d]
                     instead of stopping at the first, so they are all reported
                     together below, then type-check the best-effort AST too so
                     real type errors in the intact regions surface alongside
                     them. [--all-errors] covers text input (Wax and Wat); a Wasm
                     binary has no syntax errors to recover from and falls through
                     to the normal path. *)
               let ast_opt, syntax_errors, _ =
                 Wax_conversion.Driver.wax_parse_recover ~filename:file text
               in
               seed_recovery syntax_errors;
               match ast_opt with
               | Some ast ->
                   let ast = specialize_wax ~color ~text defines ast in
                   Wax_lang.Typing.check ~warn_unused:true d ast
               | None -> ())
           | Wat when all_errors -> (
               (* As the Wax arm, for WAT: recover every syntax error, then
                  validate the best-effort AST in recovery mode so genuine errors
                  in the intact fields surface while the warnings and stack-shape
                  cascades a dropped / auto-closed construct triggers are
                  suppressed (see [Wax_wasm.Validation]). *)
               let ast_opt, syntax_errors, _ =
                 Wax_conversion.Driver.wat_parse_recover ~filename:file text
               in
               seed_recovery syntax_errors;
               match ast_opt with
               | Some ast ->
                   let ast = specialize_wat ~color ~text defines ast in
                   Wax_wasm.Validation.f d ast
               | None -> ())
           | Wax ->
               let ast, _ =
                 Wax_parser.parse_from_string ~color ~filename:file text
               in
               let ast = specialize_wax ~color ~text defines ast in
               Wax_lang.Typing.check ~warn_unused:true d ast
           | Wat ->
               let ast, _ =
                 Wat_parser.parse_from_string ~color ~filename:file text
               in
               let ast = specialize_wat ~color ~text defines ast in
               Wax_wasm.Validation.f d ast
           | Wasm ->
               let binary = parse_wasm ~color ~filename:file text in
               Wax_wasm.Validation.f d (Wax_wasm.Binary_to_text.module_ binary)
         with Wax_utils.Diagnostic.Aborted -> ());
        match Wax_utils.Diagnostic.collected d with
        | [] -> true
        | entries ->
            (* The collected diagnostics embed types of the checked language, so
               re-report them with that language's palette. *)
            let palette =
              match fmt with
              | Wasm | Wat -> Wax_utils.Colors.wat_theme
              | Wax -> Wax_utils.Colors.wax_theme
            in
            ignore
              (Wax_utils.Diagnostic.run ~color ~palette ~source ~exit:false
                 (fun d ->
                   List.iter
                     (fun e ->
                       Wax_utils.Diagnostic.report d
                         ~location:(Wax_utils.Diagnostic.entry_location e)
                         ~severity:(Wax_utils.Diagnostic.entry_severity e)
                         ?warning:(Wax_utils.Diagnostic.entry_warning e)
                         ?hint:(Wax_utils.Diagnostic.entry_hint e)
                         ~related:(Wax_utils.Diagnostic.entry_related e)
                         ~message:(Wax_utils.Diagnostic.entry_message e)
                         ())
                     entries));
            (* Warnings (e.g. unused locals) are reported but do not fail the
               check; only errors do — including a warning promoted to an error
               by the policy (e.g. -W unused-local=error). *)
            let is_error e =
              match Wax_utils.Diagnostic.entry_severity e with
              | Wax_utils.Diagnostic.Error -> true
              | Wax_utils.Diagnostic.Warning -> (
                  match Wax_utils.Diagnostic.entry_warning e with
                  | Some w ->
                      Wax_utils.Warning.resolve policy w
                      = Wax_utils.Warning.Error
                  | None -> false)
            in
            not (List.exists is_error entries))
  in
  (* A failed check means the input was rejected, so it shares the diagnostic
     exit code (128) with convert, not the usage-error code. *)
  if not (List.fold_left (fun ok file -> check_one file && ok) true files) then
    exit 128

(*** Command-line interface ***)

(* Shell-completion helpers (cmdliner drives completion through [Cmd.eval]; a
   converter's [~completion] is what makes its option's *values* complete). *)

(* A completion offering a fixed set of literal tokens, each with a doc string. *)
let string_completion items =
  Arg.Completion.make (fun _ ~token:_ ->
      Ok (List.map (fun (s, doc) -> Arg.Completion.string ~doc s) items))

(* A string argument (a path) that completes to filenames. *)
let file_conv =
  let completion =
    Arg.Completion.make (fun _ ~token:_ -> Ok [ Arg.Completion.files ])
  in
  Arg.Conv.of_conv ~completion Arg.string

(* The wax/wat/wasm format converter, shared by every format option. *)
let format_conv =
  Arg.Conv.make ~docv:"FORMAT"
    ~completion:
      (string_completion
         [
           ("wat", "Wasm text format");
           ("wasm", "Wasm binary format");
           ("wax", "Wax language");
         ])
    ~parser:(fun s -> Result.map_error (fun (`Msg m) -> m) (format_of_string s))
    ~pp:(fun ppf f -> Format.pp_print_string ppf (string_of_format f))
    ()

(* Define the input file argument (optional for stdin) *)
let input_file =
  let doc =
    "Input file (.wat, .wasm, or .wax). Reads from stdin if not specified."
  in
  Arg.(value & pos 0 (some file_conv) None & info [] ~docv:"INPUT" ~doc)

(* Define the --output/-o option *)
let output_file =
  let doc = "Output file. Writes to stdout if not specified." in
  Arg.(
    value & opt (some file_conv) None & info [ "o"; "output" ] ~docv:"FILE" ~doc)

(* Define the --input-format option *)
let input_format =
  let doc =
    "Input format: wat (Wasm text format), wasm (Wasm binary format), or wax \
     (Wax language). If not specified, auto-detected from filename or defaults \
     to wax."
  in
  Arg.(
    value
    & opt (some format_conv) None
    & info [ "i"; "input-format" ] ~docv:"FORMAT" ~doc)

(* Define the --output-format option *)
let output_format =
  let doc =
    "Output format: wat (Wasm text format), wasm (Wasm binary format), or wax \
     (Wax language). If not specified, defaults to wax."
  in
  Arg.(
    value
    & opt (some format_conv) None
    & info [ "f"; "format"; "output-format" ] ~docv:"FORMAT" ~doc)

(* Define the --validate option *)
let validate_flag =
  let doc =
    "Force validation (type checking for Wax, well-formedness for Wasm Text) \
     and report unused locals. A text input (Wax/Wat) is already validated \
     before it is converted to a different format; this flag additionally \
     validates a same-format conversion and a trusted Wasm binary input, and \
     turns on unused-local reporting."
  in
  Arg.(value & flag & info [ "v"; "validate" ] ~doc)

let desugar_flag =
  let doc =
    "Desugar the WAT output: expand the Wax-specific $(b,(@string ...)) and \
     $(b,(@char ...)) annotations into core WebAssembly ($(b,array.new_fixed) \
     / $(b,i32.const)), producing plain WebAssembly text other tools accept. \
     Only valid with wat output. Fails if a conditional-compilation directive \
     $(b,(@if ...)) remains unresolved (resolve them with \
     $(b,-D)/$(b,--define))."
  in
  Arg.(value & flag & info [ "desugar" ] ~doc)

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
    Arg.Conv.make ~docv:"WHEN"
      ~completion:
        (string_completion
           [
             ("auto", "Color only if the output is a TTY");
             ("always", "Always color");
             ("never", "Never color");
           ])
      ~parser:(fun s ->
        Result.map_error (fun (`Msg m) -> m) (color_of_string s))
      ~pp:(fun ppf c -> Format.pp_print_string ppf (string_of_color c))
      ()
  in
  Arg.(value & opt color_conv Auto & info [ "color" ] ~docv:"WHEN" ~doc)

(* Define the --error-format option (human vs machine-readable diagnostics) *)
let error_format_option =
  let doc =
    "Diagnostic output format: $(b,human) (source snippets, the default), \
     $(b,json) (one JSON object per diagnostic per line), or $(b,short) (one \
     $(b,file:line:col: severity: message) line per diagnostic, gcc/rustc \
     style). The machine-readable forms go to stderr, for consumption by an \
     editor, CI job, or AI assistant."
  in
  let error_conv =
    Arg.Conv.make ~docv:"FORMAT"
      ~completion:
        (string_completion
           [
             ("human", "Human-readable diagnostics");
             ("json", "One JSON object per diagnostic per line");
             ( "short",
               "One file:line:col: severity: message line per diagnostic" );
           ])
      ~parser:(fun s ->
        match s with
        | "human" -> Ok Wax_utils.Diagnostic.Human
        | "json" -> Ok Wax_utils.Diagnostic.Json
        | "short" -> Ok Wax_utils.Diagnostic.Short
        | s -> Error (Printf.sprintf "Unknown error format: %s" s))
      ~pp:(fun ppf (f : Wax_utils.Diagnostic.output_format) ->
        Format.pp_print_string ppf
          (match f with Human -> "human" | Json -> "json" | Short -> "short"))
      ()
  in
  Arg.(
    value
    & opt error_conv Wax_utils.Diagnostic.Human
    & info [ "error-format" ] ~docv:"FORMAT" ~doc)

(* Define the --source-map option *)
let source_map_option =
  let doc =
    "Generate a source map file alongside the output file and insert a \
     sourceMappingURL custom section."
  in
  Arg.(value & flag & info [ "source-map" ] ~doc)

(* Define the --define/-D option (set conditional-compilation variables) *)
let define_option =
  let doc =
    "Set a conditional-compilation variable, specializing $(b,#[if(...)]) / \
     $(b,(@if ...)) annotations: fully-determined conditionals are removed and \
     partially-determined ones are simplified. $(i,NAME) on its own sets a \
     boolean to true; $(i,NAME=true)/$(i,NAME=false) set a boolean, \
     $(i,NAME=N.N.N) a version, and any other $(i,NAME=VALUE) a string. \
     Repeatable."
  in
  let define_conv =
    let parse s =
      match Wax_wasm.Cond_specialize.parse_define s with
      | Ok v -> Ok v
      | Error e -> Error (`Msg e)
    in
    let print ppf ((name, v) : string * Wax_wasm.Cond_specialize.value) =
      match v with
      | Bool b -> Format.fprintf ppf "%s=%b" name b
      | Version (a, b, c) -> Format.fprintf ppf "%s=%d.%d.%d" name a b c
      | String s -> Format.fprintf ppf "%s=%s" name s
    in
    Arg.conv (parse, print)
  in
  Arg.(
    value & opt_all define_conv []
    & info [ "D"; "define" ] ~docv:"NAME[=VALUE]" ~doc)

(* Define the --fold/--unfold option *)
let fold_mode_option =
  let doc = "Fold instructions into nested S-expressions." in
  let fold = (Fold, Arg.info [ "fold" ] ~doc) in
  let doc = "Unfold instructions into flat instruction lists." in
  let unfold = (Unfold, Arg.info [ "unfold" ] ~doc) in
  Arg.(value & vflag Auto [ fold; unfold ])

(* Define the --debug option (enable developer debug output by category) *)
let debug_option =
  let doc =
    "Enable debug output for $(i,CATEGORY) (repeatable, comma-separated). \
     Categories: timing (log the wall-clock running time of each compiler \
     pass)."
  in
  let category_conv =
    Arg.Conv.make ~docv:"CATEGORY" ~parser:Wax_utils.Debug.parse
      ~pp:(fun ppf c ->
        Format.pp_print_string ppf
          (match (c : Wax_utils.Debug.category) with Timing -> "timing"))
      ()
  in
  (* The value is a comma-separated list, so [list category_conv]'s own
     completion (not the element's) is what fires; complete the last segment,
     preserving any earlier comma-separated prefix. *)
  let category_completion =
    Arg.Completion.make (fun _ ~token ->
        let prefix =
          match String.rindex_opt token ',' with
          | Some i -> String.sub token 0 (i + 1)
          | None -> ""
        in
        Ok
          (List.map
             (fun c -> Arg.Completion.string (prefix ^ c))
             Wax_utils.Debug.categories))
  in
  Arg.(
    value
    & opt_all
        (Arg.Conv.of_conv ~completion:category_completion (list category_conv))
        []
    & info [ "debug" ] ~docv:"CATEGORY" ~doc)

(* Define the --warn/-W option (set the level of a named warning or group) *)
let warn_option =
  let doc =
    "Set the reporting level of a warning, specializing how diagnostics are \
     handled. $(i,NAME) is a warning name (e.g. unused-local), a group (e.g. \
     unused), or $(b,all); $(i,LEVEL) is $(b,hidden), $(b,warning), or \
     $(b,error). Later settings override earlier ones, so $(b,-W all=error -W \
     unused-local=warning) makes every warning fatal except unused locals. \
     Repeatable. The $(b,WAX_WARN) environment variable sets defaults applied \
     before these (see the ENVIRONMENT section)."
  in
  (* [NAME=LEVEL]: before the [=] complete the warning/group names, after it the
     three levels (as full [NAME=LEVEL] tokens, since a directive replaces the
     whole argument). *)
  let warn_completion =
    Arg.Completion.make (fun _ ~token ->
        match String.index_opt token '=' with
        | Some i ->
            let name = String.sub token 0 i in
            Ok
              (List.map
                 (fun lvl -> Arg.Completion.string (name ^ "=" ^ lvl))
                 [ "hidden"; "warning"; "error" ])
        | None ->
            let warnings =
              List.map
                (fun w ->
                  Arg.Completion.string
                    ~doc:(Wax_utils.Warning.description w)
                    (Wax_utils.Warning.name w))
                Wax_utils.Warning.all
            in
            let groups =
              List.map
                (fun g -> Arg.Completion.string ~doc:"warning group" g)
                ("all" :: Wax_utils.Warning.groups)
            in
            Ok (warnings @ groups))
  in
  let warn_conv =
    let parse s =
      match Wax_utils.Warning.parse_spec s with
      | Error e -> Error e
      | Ok (name, level) -> (
          (* Reject an unknown name now (rather than when building the policy)
             so the error is reported like any other argument error. *)
          match
            Wax_utils.Warning.set Wax_utils.Warning.default_policy name level
          with
          | Ok _ -> Ok (name, level)
          | Error e -> Error e)
    in
    let print ppf ((name, level) : string * Wax_utils.Warning.level) =
      let level =
        match level with
        | Hidden -> "hidden"
        | Displayed -> "warning"
        | Error -> "error"
      in
      Format.fprintf ppf "%s=%s" name level
    in
    Arg.Conv.make ~docv:"NAME=LEVEL" ~completion:warn_completion ~parser:parse
      ~pp:print ()
  in
  Arg.(
    value & opt_all warn_conv [] & info [ "W"; "warn" ] ~docv:"NAME=LEVEL" ~doc)

(* Define the --feature/-X option (enable/disable optional proposals) *)
let feature_option =
  let doc =
    "Enable or disable an optional feature / proposal. $(i,NAME) or \
     $(i,NAME=on) enables it, $(i,NAME=off) disables it. Repeatable; later \
     settings win. Known: $(b,custom-descriptors), $(b,compact-import-section) \
     (both off by default)."
  in
  (* [NAME[=on|off]]: before the [=] complete the feature names, after it the two
     values (as full tokens). *)
  let feature_completion =
    Arg.Completion.make (fun _ ~token ->
        match String.index_opt token '=' with
        | Some i ->
            let name = String.sub token 0 i in
            Ok
              (List.map
                 (fun v -> Arg.Completion.string (name ^ "=" ^ v))
                 [ "on"; "off" ])
        | None ->
            Ok
              (List.map
                 (fun f -> Arg.Completion.string (Wax_utils.Feature.name f))
                 Wax_utils.Feature.all))
  in
  let feature_conv =
    Arg.Conv.make ~docv:"NAME" ~completion:feature_completion
      ~parser:Wax_utils.Feature.parse_spec
      ~pp:(fun ppf ((t, b) : Wax_utils.Feature.t * bool) ->
        Format.fprintf ppf "%s=%s" (Wax_utils.Feature.name t)
          (if b then "on" else "off"))
      ()
  in
  Arg.(
    value & opt_all feature_conv [] & info [ "X"; "feature" ] ~docv:"NAME" ~doc)

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
  Arg.(
    value
    & opt (some format_conv) None
    & info [ "f"; "format"; "input-format" ] ~docv:"FORMAT" ~doc)

(* Define the input files of the format command. Zero files is allowed: the
   command then formats standard input to standard output (see [format]). *)
let format_files =
  let doc =
    "Input files (.wat, .wasm or .wax) to format. With none, standard input is \
     formatted to standard output (requires --format)."
  in
  Arg.(value & pos_all file_conv [] & info [] ~docv:"FILE" ~doc)

(* Define the input files of the check command *)
let check_files =
  let doc = "Input files (.wat, .wasm or .wax) to validate." in
  Arg.(non_empty & pos_all file_conv [] & info [] ~docv:"FILE" ~doc)

(* Define the --all-errors flag (check command) *)
let all_errors_flag =
  let doc =
    "Report every syntax error instead of stopping at the first, using \
     panic-mode error recovery, then check the best-effort AST so genuine \
     type/validation errors in the intact regions surface alongside the syntax \
     errors. Text input only, Wax and Wat (ignored for a Wasm binary)."
  in
  Arg.(value & flag & info [ "all-errors" ] ~doc)

(* Combine into command *)
let convert_term =
  let+ input = input_file
  and+ output = output_file
  and+ in_fmt = input_format
  and+ out_fmt = output_format
  and+ validate = validate_flag
  and+ strict_validate = strict_validate_flag
  and+ color = color_option
  and+ source_map = source_map_option
  and+ fold_mode = fold_mode_option
  and+ desugar = desugar_flag
  and+ defines = define_option
  and+ warnings = warn_option
  and+ features = feature_option
  and+ debug = debug_option
  and+ error_format = error_format_option in
  convert input output in_fmt out_fmt validate strict_validate color source_map
    fold_mode desugar defines warnings features (List.concat debug) error_format

let format_term =
  let+ inplace = inplace_flag
  and+ check = check_flag
  and+ format_opt = format_input
  and+ color = color_option
  and+ fold_mode = fold_mode_option
  and+ warnings = warn_option
  and+ debug = debug_option
  and+ error_format = error_format_option
  and+ files = format_files in
  format inplace check format_opt color fold_mode warnings (List.concat debug)
    error_format files

(* Exit codes, documented in docs/src/cli.md. Given explicitly rather than
   extending [Cmd.Exit.defaults] because the toolchain repurposes 123 (usage
   error, not cmdliner's generic "some error") and adds 128 (rejected input);
   0/124/125 keep cmdliner's standard meaning. This only drives the generated
   --help, so it matches the reference. *)
let exits =
  [
    Cmd.Exit.info 0 ~doc:"on success.";
    Cmd.Exit.info 123
      ~doc:
        "on a usage error (an invalid flag combination), or a $(b,format \
         --check) run that found files needing formatting.";
    Cmd.Exit.info 124 ~doc:"on command line parsing errors.";
    Cmd.Exit.info 125 ~doc:"on unexpected internal errors (bugs).";
    Cmd.Exit.info 128
      ~doc:
        "on rejected input: a parse, validation or type error, or a malformed \
         wasm binary (also a $(b,check) run that found any problem).";
  ]

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
  Cmd.v (Cmd.info "format" ~doc ~man ~exits ~envs:[ warn_env_info ]) format_term

let check_term =
  let+ format_opt = format_input
  and+ strict = strict_validate_flag
  and+ color = color_option
  and+ warnings = warn_option
  and+ features = feature_option
  and+ debug = debug_option
  and+ error_format = error_format_option
  and+ defines = define_option
  and+ all_errors = all_errors_flag
  and+ files = check_files in
  check format_opt strict color warnings features (List.concat debug)
    error_format defines all_errors files

let check_cmd =
  let doc = "Validate WebAssembly files without producing output" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Parse and validate each input file (type-checking for Wax, \
         well-formedness for Wasm) without producing any output. Reports \
         diagnostics and exits with a non-zero status if any file fails.";
      `P
        "The format of each file is detected from its extension unless \
         --format forces one.";
      `S Manpage.s_examples;
      `P "Type-check several Wax files:";
      `Pre "  $(mname) $(tname) src/*.wax";
      `S Manpage.s_options;
    ]
  in
  Cmd.v (Cmd.info "check" ~doc ~man ~exits ~envs:[ warn_env_info ]) check_term

let lsp_term =
  (* [--stdio] is accepted (and ignored) so the many editors that pass it by
     convention do not error; stdin/stdout is the only transport. *)
  let+ (_ : bool) =
    Arg.(
      value & flag
      & info [ "stdio" ]
          ~doc:"Communicate over stdin/stdout (the default and only transport).")
  in
  Wax_lsp.run ()

let lsp_cmd =
  let doc = "Run the Wax language server (LSP) over stdin/stdout" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Start a Language Server Protocol server for Wax and Wasm text, \
         communicating over stdin/stdout. Point an LSP-capable editor (Neovim, \
         Emacs, Helix, and others) at this command to get diagnostics, hover, \
         go-to-definition, find-references, rename, completion, signature \
         help, inlay hints, document symbols, folding, selection ranges, \
         semantic tokens, and formatting.";
      `P
        "The server reuses the same analysis as the VS Code extension; it adds \
         no configuration of its own.";
      `S Manpage.s_examples;
      `P "Most editors are configured with the command to launch:";
      `Pre "  $(mname) $(tname)";
      `S Manpage.s_options;
    ]
  in
  Cmd.v (Cmd.info "lsp" ~doc ~man ~exits ~envs:[ warn_env_info ]) lsp_term

let convert_cmd =
  let doc = "Convert between WebAssembly formats (the default command)" in
  Cmd.v (Cmd.info "convert" ~doc ~exits ~envs:[ warn_env_info ]) convert_term

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
      `P "Validate files:";
      `Pre "  $(tname) check src/*.wax";
      `S Manpage.s_options;
    ]
  in
  Cmd.group
    (Cmd.info "wax" ~doc ~man ~exits ~envs:[ warn_env_info ])
    ~default:convert_term
    [ convert_cmd; format_cmd; check_cmd; lsp_cmd ]

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
  (* A syntax error escapes the parser as [Syntax_error] (already reported); map
     it to the rejected-input exit code 128. [~catch:false] lets it through
     cmdliner's own catch-all (which would otherwise report it as an internal
     error, 125); we keep that 125 behaviour for any genuinely unexpected
     exception here. *)
  let code =
    try Cmd.eval ~catch:false ~argv main_cmd with
    | Wax_wasm.Parsing.Syntax_error _ -> 128
    | e ->
        Printf.eprintf "wax: internal error, uncaught exception:\n%s\n"
          (Printexc.to_string e);
        Cmd.Exit.internal_error
  in
  exit code
