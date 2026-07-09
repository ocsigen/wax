(* The Wax toolchain's formatter and checker exported to JavaScript, for the VS
   Code extension. It runs in-process under wasm_of_ocaml in both Node (the
   desktop extension host) and the browser (the web extension), and installs
   [globalThis.wax] with methods for both the Wax and the Wasm-text languages:

   - [format src] / [formatWat src] -> { ok; text; error }: reprint the module
     with its comments preserved (mirrors [wax_to_wax] / [wat_to_wat] in
     bin/main.ml), or report why it could not.
   - [check src] / [checkWat src] -> array of { severity; message; startLine;
     startChar; endLine; endChar; hint; related }: parse and check (type-check
     for Wax, validate for Wasm text), returning diagnostics for the editor.
   - [symbols src] / [symbolsWat src] -> the module's top-level definitions, for
     the outline.
   - [toWat src] / [toWax src] -> { ok; text; error }: convert between the
     languages (compile Wax to Wasm text, decompile Wasm text to Wax), for the
     side-by-side preview commands.

   Shipping both languages in one wasm module (rather than two) keeps a single
   build and load path; the WAT lexer/parser/validator it adds cost ~0.5 MB.

   Parsing goes through [parse_diagnostics], which yields the AST or a structured
   error without printing or exiting (and without the fast parser), so a syntax
   error becomes an editor squiggle rather than stderr noise. *)

open Js_of_ocaml

(* The editor parses through [parse_diagnostics], which uses the incremental
   parser directly, so it instantiates {!Wax_wasm.Parsing.Make} — the core
   functor without a [Fast_parser] parameter. That keeps [Wax_lang.Fast_parser]
   and its tables out of the linked program (the bytecode linker pulls in a whole
   compilation unit as soon as it is referenced, even only as a functor
   argument). *)
module Wax_parser =
  Wax_wasm.Parsing.Make
    (struct
      type t = Wax_lang.Ast.location Wax_lang.Ast.module_
    end)
    (Wax_lang.Tokens)
    (Wax_lang.Parser)
    (Wax_lang.Parser_messages)
    (Wax_lang.Lexer)

(* The Wasm-text parser, instantiated the same way (no fast parser). Its lexer,
   parser and {!Wax_wasm.Validation} are what make this module cover WAT too. *)
module Wat_parser =
  Wax_wasm.Parsing.Make
    (struct
      type t = Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
    end)
    (Wax_wasm.Tokens)
    (Wax_wasm.Parser)
    (Wax_wasm.Parser_messages)
    (Wax_wasm.Lexer)

(* A formatter that discards everything, for the dry pass that records which
   source locations the printer looks up (as in bin/main.ml). *)
let null_formatter () = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ())

(* Comments and blank-line trivia keyed by source location, restricted to the
   locations the printer actually visits. [retarget], when given, rewrites the
   comment delimiters from the source language's syntax to the target's (used by
   the cross-language conversions, whose converted nodes carry the source
   locations). Same logic as [wax_trivia] / [wat_trivia] in bin/main.ml. *)
let wax_trivia ?retarget ctx ast =
  let used = Hashtbl.create 256 in
  Wax_utils.Printer.run (null_formatter ()) (fun p ->
      Wax_lang.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used ast);
  let trivia, tail = Wax_utils.Trivia.associate ~only:used ctx in
  match retarget with
  | None -> (trivia, tail)
  | Some (src, dst) -> Wax_utils.Trivia.retarget ~src ~dst trivia tail

let wat_trivia ?retarget ctx ast =
  let used = Hashtbl.create 256 in
  Wax_utils.Printer.run (null_formatter ()) (fun p ->
      Wax_wasm.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used ast);
  let trivia, tail = Wax_utils.Trivia.associate ~only:used ctx in
  match retarget with
  | None -> (trivia, tail)
  | Some (src, dst) -> Wax_utils.Trivia.retarget ~src ~dst trivia tail

let format_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } -> Error (String.trim message)
  | Ok (ast, ctx) ->
      let trivia, tail = wax_trivia ctx ast in
      let buf = Buffer.create (String.length src) in
      let fmt = Format.formatter_of_buffer buf in
      let print_wax f m =
        Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
            Wax_lang.Output.module_ p ~trivia ~tail m)
      in
      Format.fprintf fmt "%a@." print_wax ast;
      Ok (Buffer.contents buf)

let format_wat_string src =
  match Wat_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } -> Error (String.trim message)
  | Ok (ast, ctx) ->
      let trivia, tail = wat_trivia ctx ast in
      let buf = Buffer.create (String.length src) in
      let fmt = Format.formatter_of_buffer buf in
      let print_wat f m =
        Wax_utils.Printer.run f (fun p ->
            Wax_wasm.Output.module_ ~color:Wax_utils.Colors.Never p ~trivia
              ~tail m)
      in
      Format.fprintf fmt "%a@." print_wat ast;
      Ok (Buffer.contents buf)

type diag = {
  severity : Wax_utils.Diagnostic.severity;
  location : Wax_utils.Ast.location;
  message : string;
  hint : string option;
  related : (string * Wax_utils.Ast.location) list;
      (* a message and the source span it points at (e.g. the matching opener) *)
}

let render f = Format.asprintf "%a" f ()

let render_labels labels =
  List.map
    (fun (l : Wax_utils.Diagnostic.label) -> (render l.message, l.location))
    labels

(* The single syntax error the parser returns, as a diagnostic (with its related
   labels but no hint). *)
let syntax_error_diag (e : Wax_wasm.Parsing.syntax_error) =
  {
    severity = Wax_utils.Diagnostic.Error;
    location = e.location;
    message = e.message;
    hint = None;
    related = render_labels e.related;
  }

(* The errors and warnings a checker collected (without printing), as diagnostics
   carrying their hints and related labels. *)
let collected_diags d =
  List.map
    (fun e ->
      {
        severity = Wax_utils.Diagnostic.entry_severity e;
        location = Wax_utils.Diagnostic.entry_location e;
        message = render (Wax_utils.Diagnostic.entry_message e);
        hint = Option.map render (Wax_utils.Diagnostic.entry_hint e);
        related = render_labels (Wax_utils.Diagnostic.entry_related e);
      })
    (Wax_utils.Diagnostic.collected d)

(* Diagnostics: a syntax error (one, from the parser) or, if parsing succeeds,
   the checker's errors and warnings collected without printing. For Wax that
   checker is the type-checker; for Wasm text it is the validator. *)
let check_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error e -> [ syntax_error_diag e ]
  | Ok (ast, _ctx) ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      (try Wax_lang.Typing.check ~warn_unused:true d ast
       with Wax_utils.Diagnostic.Aborted -> ());
      collected_diags d

let check_wat_string src =
  match Wat_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error e -> [ syntax_error_diag e ]
  | Ok (ast, _ctx) ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      (try Wax_wasm.Validation.f ~warn_unused:true d ast
       with Wax_utils.Diagnostic.Aborted -> ());
      collected_diags d

(* Whether a collector holds any error (as opposed to only warnings), and its
   errors joined into one message. Used by the conversions, which need a
   well-typed / valid input and so give up — reporting why — on any error. *)
let has_errors d =
  List.exists
    (fun e ->
      Wax_utils.Diagnostic.entry_severity e = Wax_utils.Diagnostic.Error)
    (Wax_utils.Diagnostic.collected d)

let errors_string d =
  Wax_utils.Diagnostic.collected d
  |> List.filter (fun e ->
      Wax_utils.Diagnostic.entry_severity e = Wax_utils.Diagnostic.Error)
  |> List.map (fun e -> render (Wax_utils.Diagnostic.entry_message e))
  |> String.concat "\n"

(* Cross-language conversion, for the preview commands. [to_wat] compiles Wax to
   Wasm text (mirrors [wax_to_wat] in bin/main.ml: type-check, [To_wasm], print);
   [to_wax] decompiles Wasm text to Wax ([wat_to_wax]: [From_wasm], re-type and
   erase, print). Both trust their input is well formed once it has no errors, so
   they return the source's diagnostics rather than a partial result on failure.
   The converted nodes carry the source locations, so the source comments map
   onto them once their delimiters are retargeted to the other syntax. *)
let to_wat_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } -> Error (String.trim message)
  | Ok (ast, ctx) -> (
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      try
        let types, ast = Wax_lang.Typing.f ~warn_unused:false d ast in
        if has_errors d then Error (errors_string d)
        else
          let wasm_ast = Wax_conversion.To_wasm.module_ d types ast in
          let trivia, tail =
            wat_trivia
              ~retarget:
                (Wax_utils.Trivia.wax_syntax, Wax_utils.Trivia.wat_syntax)
              ctx wasm_ast
          in
          let buf = Buffer.create (String.length src) in
          let fmt = Format.formatter_of_buffer buf in
          let print_wat f m =
            Wax_utils.Printer.run f (fun p ->
                Wax_wasm.Output.module_ ~color:Wax_utils.Colors.Never p ~trivia
                  ~tail m)
          in
          Format.fprintf fmt "%a@." print_wat wasm_ast;
          Ok (Buffer.contents buf)
      with Wax_utils.Diagnostic.Aborted -> Error (errors_string d))

let to_wax_string src =
  match Wat_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } -> Error (String.trim message)
  | Ok (ast, ctx) -> (
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      try
        let wax_ast = Wax_conversion.From_wasm.module_ d ast in
        if has_errors d then Error (errors_string d)
        else
          let wax_ast =
            Wax_lang.Typing.f ~simplify:true d wax_ast
            |> snd |> Wax_lang.Typing.erase_types
          in
          let trivia, tail =
            wax_trivia
              ~retarget:
                (Wax_utils.Trivia.wat_syntax, Wax_utils.Trivia.wax_syntax)
              ctx wax_ast
          in
          let buf = Buffer.create (String.length src) in
          let fmt = Format.formatter_of_buffer buf in
          let print_wax f m =
            Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
                Wax_lang.Output.module_ p ~trivia ~tail m)
          in
          Format.fprintf fmt "%a@." print_wax wax_ast;
          Ok (Buffer.contents buf)
      with Wax_utils.Diagnostic.Aborted -> Error (errors_string d))

(* VS Code positions are zero-based for both line and character; Lexing lines are
   one-based and [pos_cnum - pos_bol] is the zero-based column. *)
let js_position (p : Lexing.position) =
  (p.Lexing.pos_lnum - 1, p.Lexing.pos_cnum - p.Lexing.pos_bol)

let js_related (message, (location : Wax_utils.Ast.location)) =
  let start_line, start_char = js_position location.loc_start in
  let end_line, end_char = js_position location.loc_end in
  object%js
    val message = Js.string (String.trim message)
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
  end

let js_diagnostic d =
  let start_line, start_char = js_position d.location.loc_start in
  let end_line, end_char = js_position d.location.loc_end in
  object%js
    val severity =
      Js.string
        (match d.severity with
        | Wax_utils.Diagnostic.Error -> "error"
        | Warning -> "warning")

    val message = Js.string (String.trim d.message)
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char

    val hint =
      match d.hint with
      | Some h -> Js.some (Js.string (String.trim h))
      | None -> Js.null

    val related = Js.array (Array.of_list (List.map js_related d.related))
  end

let result ~ok ~text ~error =
  object%js
    val ok = Js.bool ok

    val text =
      match text with Some t -> Js.some (Js.string t) | None -> Js.null

    val error =
      match error with Some e -> Js.some (Js.string e) | None -> Js.null
  end

(* Never let a failure escape as an uncaught exception: [format] reports
   [ok:false] so the provider leaves the buffer untouched, and [check] returns no
   diagnostics rather than crashing the extension host. [format_fn]/[check_fn]
   select the language (Wax or Wasm text). *)
let format_result format_fn src =
  try
    match format_fn (Js.to_string src) with
    | Ok text -> result ~ok:true ~text:(Some text) ~error:None
    | Error message -> result ~ok:false ~text:None ~error:(Some message)
  with exn ->
    result ~ok:false ~text:None ~error:(Some (Printexc.to_string exn))

let check_result check_fn src =
  let diagnostics = try check_fn (Js.to_string src) with _ -> [] in
  Js.array (Array.of_list (List.map js_diagnostic diagnostics))

(* Document outline: the module's top-level definitions (functions, globals,
   types, memories, tags, tables, elems, data, imports) with their spans, for the
   editor's outline / breadcrumbs. Only a syntactically-valid module yields
   symbols. *)
type sym = {
  s_name : string;
  s_kind : string;
  s_range : Wax_utils.Ast.location; (* the whole definition span *)
  s_selection : Wax_utils.Ast.location; (* the name span *)
  s_children : sym list;
}

let import_kind_str (k : Wax_lang.Ast.import_kind) =
  match k with
  | Import_func _ -> "function"
  | Import_global _ -> "variable"
  | Import_tag _ -> "event"
  | Import_memory _ -> "memory"
  | Import_table _ -> "table"

let import_symbol
    (decl :
      (Wax_lang.Ast.import_decl, Wax_utils.Ast.location) Wax_lang.Ast.annotated)
    =
  let d = decl.desc in
  {
    s_name = d.id.desc;
    s_kind = import_kind_str d.kind;
    s_range = decl.info;
    s_selection = d.id.info;
    s_children = [];
  }

let field_symbols
    (field :
      ( Wax_utils.Ast.location Wax_lang.Ast.modulefield,
        Wax_utils.Ast.location )
      Wax_lang.Ast.annotated) : sym list =
  let open Wax_lang.Ast in
  let one s_name s_kind s_selection =
    { s_name; s_kind; s_range = field.info; s_selection; s_children = [] }
  in
  match field.desc with
  | Func { name; _ } -> [ one name.desc "function" name.info ]
  | Global { name; _ } -> [ one name.desc "variable" name.info ]
  | Tag { name; _ } -> [ one name.desc "event" name.info ]
  | Memory { name; _ } -> [ one name.desc "memory" name.info ]
  | Table { name; _ } -> [ one name.desc "table" name.info ]
  | Elem { name; _ } -> [ one name.desc "array" name.info ]
  | Data { name = Some n; _ } -> [ one n.desc "data" n.info ]
  | Data { name = None; _ } -> []
  | Type rectype ->
      Array.to_list rectype
      |> List.map (fun entry ->
          let id, _ = entry.desc in
          {
            s_name = id.desc;
            s_kind = "type";
            s_range = entry.info;
            s_selection = id.info;
            s_children = [];
          })
  | Import { decl; _ } -> [ import_symbol decl ]
  | Import_group { module_; decls } ->
      [
        {
          s_name = module_.desc;
          s_kind = "namespace";
          s_range = field.info;
          s_selection = module_.info;
          s_children = List.map import_symbol decls;
        };
      ]
  | Module_annotation _ | Conditional _ -> []

let symbols_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error _ -> []
  | Ok (ast, _ctx) -> List.concat_map field_symbols ast

(* The same outline for a Wasm-text module. Its fields differ from Wax's: the
   [$id] name is optional, and a definition carries its exports separately, so an
   anonymous definition is named by its first export, else by a fallback word. *)
let wat_field_symbols
    (field :
      ( Wax_utils.Ast.location Wax_wasm.Ast.Text.modulefield,
        Wax_utils.Ast.location )
      Wax_wasm.Ast.annotated) : sym list =
  (* [Ast] for the [annotated] record labels ([desc]/[info]); [Ast.Text] for the
     module-field constructors. *)
  let open Wax_wasm.Ast in
  let open Wax_wasm.Ast.Text in
  let one s_name s_kind s_selection =
    { s_name; s_kind; s_range = field.info; s_selection; s_children = [] }
  in
  (* The lexer stores a [$id] without its leading [$] (but the id's span still
     covers it). Render it exactly as the printer does (so an id that is not a
     plain identifier gets the quoted [$"…"] form); this also distinguishes an id
     from an export name, which is shown bare. *)
  let id_name (n : name) = Wax_wasm.Output.id_string n.desc in
  let named (id : name option) (exports : name list) kind fallback =
    match id with
    | Some n -> [ one (id_name n) kind n.info ]
    | None -> (
        match exports with
        | e :: _ -> [ one e.desc kind e.info ]
        | [] -> [ one fallback kind field.info ])
  in
  match field.desc with
  | Func { id; exports; _ } -> named id exports "function" "func"
  | Global { id; exports; _ } -> named id exports "variable" "global"
  | Memory { id; exports; _ } -> named id exports "memory" "memory"
  | Table { id; exports; _ } -> named id exports "table" "table"
  | Tag { id; exports; _ } -> named id exports "event" "tag"
  | Elem { id = Some n; _ } -> [ one (id_name n) "array" n.info ]
  | Elem { id = None; _ } -> []
  | Data { id = Some n; _ } -> [ one (id_name n) "data" n.info ]
  | Data { id = None; _ } -> []
  | String_global { id; _ } -> [ one (id_name id) "variable" id.info ]
  | Import { module_; name; id; desc; _ } ->
      let kind =
        match desc with
        | Func _ -> "function"
        | Memory _ -> "memory"
        | Table _ -> "table"
        | Global _ -> "variable"
        | Tag _ -> "event"
      in
      let s_name, s_selection =
        match id with
        | Some n -> (id_name n, n.info)
        | None -> (module_.desc ^ "." ^ name.desc, field.info)
      in
      [ one s_name kind s_selection ]
  | Types rectype ->
      Array.to_list rectype
      |> List.filter_map (fun entry ->
          let id, _ = entry.desc in
          match (id : name option) with
          | Some n ->
              Some
                {
                  s_name = id_name n;
                  s_kind = "type";
                  s_range = entry.info;
                  s_selection = n.info;
                  s_children = [];
                }
          | None -> None)
  | Export _ | Start _ -> []
  | Module_if_annotation _ -> []

let symbols_wat_string src =
  match Wat_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error _ -> []
  | Ok ((_name, fields), _ctx) -> List.concat_map wat_field_symbols fields

let rec js_symbol s =
  let start_line, start_char = js_position s.s_range.loc_start in
  let end_line, end_char = js_position s.s_range.loc_end in
  let sel_start_line, sel_start_char = js_position s.s_selection.loc_start in
  let sel_end_line, sel_end_char = js_position s.s_selection.loc_end in
  object%js
    val name = Js.string s.s_name
    val kind = Js.string s.s_kind
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
    val selStartLine = sel_start_line
    val selStartChar = sel_start_char
    val selEndLine = sel_end_line
    val selEndChar = sel_end_char
    val children = Js.array (Array.of_list (List.map js_symbol s.s_children))
  end

let symbols_result symbols_fn src =
  let syms = try symbols_fn (Js.to_string src) with _ -> [] in
  Js.array (Array.of_list (List.map js_symbol syms))

let () =
  Js.export "wax"
    object%js
      method format src = format_result format_string src
      method check src = check_result check_string src
      method symbols src = symbols_result symbols_string src
      method formatWat src = format_result format_wat_string src
      method checkWat src = check_result check_wat_string src
      method symbolsWat src = symbols_result symbols_wat_string src
      method toWat src = format_result to_wat_string src
      method toWax src = format_result to_wax_string src
    end
