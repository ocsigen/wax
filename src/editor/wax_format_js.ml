(* The Wax toolchain's formatter and checker exported to JavaScript, for the VS
   Code extension. It runs in-process under wasm_of_ocaml in both Node (the
   desktop extension host) and the browser (the web extension), and installs
   [globalThis.wax] with methods for both the Wax and the Wasm-text languages:

   - [format src] / [formatWat src] -> { ok; text; error }: reprint the module
     with its comments preserved (mirrors [wax_to_wax] / [wat_to_wat] in
     bin/main.ml), or report why it could not.
   - [check src] / [checkWat src] -> array of { severity; message; startLine;
     startChar; endLine; endChar; warning; hint; related }: parse and check
     (type-check for Wax, validate for Wasm text), returning diagnostics for the
     editor. [warning] is the [-W] name of a lint warning, or null.
   - [hover src line ch] -> { type; startLine; startChar; endLine; endChar } or
     null: for editor hover at the (zero-based) position. The type of the
     innermost expression under the cursor, or — for a name that is not an
     expression and so is more specific than any expression enclosing it (a type
     reference, an assignment target, a bare global) — what that name resolves to
     (a type's definition, a variable's type). [null] over a statement or an
     unresolved node, so those stay quiet. Wax only (WAT builds no typed tree).
   - [inlays src] -> array of { line; char; label }: the inferred type on each
     un-annotated [let] binding ([: i32] after [x] in [let x = 3]), for inlay
     hints. Wax only.
   - [definition src line ch] -> array of { startLine; startChar; endLine;
     endChar }: the definition span(s) for the name or label use at the
     (zero-based) position, for go-to-definition. Several only for a name defined
     in multiple conditional-compilation branches. Wax only.
   - [references src line ch] -> array of { startLine; startChar; endLine;
     endChar }: every occurrence (definitions and uses) of the symbol at the
     (zero-based) position, for find-references and document highlight. Wax only.
   - [symbols src] / [symbolsWat src] -> the module's top-level definitions, for
     the outline.
   - [toWat src] / [toWax src] -> { ok; text; error }: convert between the
     languages (compile Wax to Wasm text, decompile Wasm text to Wax), for the
     side-by-side preview commands.

   Shipping both languages in one wasm module (rather than two) keeps a single
   build and load path; the WAT lexer/parser/validator it adds cost ~0.5 MB.

   Parsing goes through [parse_diagnostics], which yields the AST or a structured
   error without printing or exiting (and without the fast parser), so a syntax
   error becomes an editor squiggle rather than stderr noise. The Wax [check]
   uses [parse_recover] instead, so a buffer with several syntax errors squiggles
   all of them at once rather than only the first. *)

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
  warning : string option; (* the [-W] name of a lint warning, if any *)
  hint : string option;
  related : (string * Wax_utils.Ast.location) list;
      (* a message and the source span it points at (e.g. the matching opener) *)
}

let render f = Format.asprintf "%a" f ()

let render_labels labels =
  List.map
    (fun (l : Wax_utils.Diagnostic.label) -> (render l.message, l.location))
    labels

(* A syntax error, as a diagnostic (with its related labels but no hint). *)
let syntax_error_diag (e : Wax_wasm.Parsing.syntax_error) =
  {
    severity = Wax_utils.Diagnostic.Error;
    location = e.location;
    message = e.message;
    warning = None;
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
        warning =
          Option.map Wax_utils.Warning.name
            (Wax_utils.Diagnostic.entry_warning e);
        hint = Option.map render (Wax_utils.Diagnostic.entry_hint e);
        related = render_labels (Wax_utils.Diagnostic.entry_related e);
      })
    (Wax_utils.Diagnostic.collected d)

(* One parse + type-check of a Wax buffer, shared by [check] (which wants the
   diagnostics) and [hover] (which wants the typed tree). Parse with panic-mode
   recovery ([parse_recover]) so a buffer with several syntax errors surfaces all
   of them as squiggles at once, not just the first — the editor is exactly the
   multi-error consumer recovery exists for. The best-effort AST is then
   type-checked with [Typing.f_infer], which both collects diagnostics and builds
   the typed tree (annotation = inference cells + span at every node): real type
   errors in the intact regions still show while the user fixes the syntax, and
   the tree is what hover reads. When recovered past syntax errors the checker
   runs in recovery mode ([set_recovery]), which suppresses the "not bound"
   cascades from the dropped constructs.

   [f_infer] emits the same diagnostics as [Typing.check] — for a
   conditional-free module both run the one checking pass, and for [#[if]]
   modules both run the path-sensitive [check_configurations]; [f_infer] only
   does an extra throwaway-collector pass to build the tree. So routing
   diagnostics through it leaves them unchanged and gets the tree for free. *)
type analysis = {
  a_syntax : diag list;
  a_type : diag list;
  a_typed :
    Wax_lang.Typing.inferred_module_annotation Wax_lang.Ast.module_ option;
  a_defs : Wax_lang.Typing.reference list;
      (* use -> definition(s) references, for go-to-definition. *)
}

let analyze_uncached src =
  let ast_opt, syntax_errors, _ctx =
    Wax_parser.parse_recover ~filename:"<buffer>" ~sync:Wax_lang.Recover.sync
      ~insert:Wax_lang.Recover.insert ~closers:Wax_lang.Recover.closers src
  in
  let a_syntax = List.map syntax_error_diag syntax_errors in
  match ast_opt with
  | None -> { a_syntax; a_type = []; a_typed = None; a_defs = [] }
  | Some ast ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      Wax_utils.Diagnostic.set_recovery d (syntax_errors <> []);
      (* [f_infer] may abort mid-pass; the diagnostics it collected up to that
         point still stand (as with [check] before), so read [d] regardless. It
         emits the same diagnostics as [f]/[check] but keeps the inference cells
         (which hover renders via [Infer.output_inferred_type]) and, given a
         sink, records the use -> definition references go-to-definition needs. *)
      let links = ref [] in
      let a_typed =
        try
          Some
            (snd
               (Wax_lang.Typing.f_infer ~warn_unused:true
                  ~resolve_links:(Some links) d ast))
        with Wax_utils.Diagnostic.Aborted -> None
      in
      { a_syntax; a_type = collected_diags d; a_typed; a_defs = !links }

(* Cache the analysis, keyed by the exact source, so hover — invoked repeatedly
   on an unchanged buffer, once per mouse-hover — does not re-parse and
   re-type-check each time, and shares the diagnostics pass's work. A handful of
   recent buffers are kept (several files may be open); an edit changes the
   source and so is a fresh entry, evicting the oldest. Keeping the source as the
   key (not a hash) means a hit is exact — never a collision serving a wrong
   tree. *)
let analysis_cache_size = 4
let analysis_cache : (string * analysis) list ref = ref []

let analyze src =
  match List.assoc_opt src !analysis_cache with
  | Some a -> a
  | None ->
      let a = analyze_uncached src in
      analysis_cache :=
        (src, a)
        :: List.filteri (fun i _ -> i < analysis_cache_size - 1) !analysis_cache;
      a

let check_string src =
  let a = analyze src in
  a.a_syntax @ a.a_type

(* Hover types (Wax only). Reads the cell-annotated tree [analyze] built (every
   node's [info] is the inference cells for the values it leaves on the stack,
   paired with its source span), then keeps the smallest span that covers the
   cursor and renders its type — the innermost-node walk an editor hover wants,
   done with the same recursive [map_modulefield] the outline uses. [line]/[ch]
   are the raw zero-based VS Code coordinates ([ch] a UTF-16 column, mapped to a
   byte column by [byte_column]). WAT has no equivalent — its validator builds no
   typed tree. *)
type hover = { h_type : string; h_range : Wax_utils.Ast.location }

let cell_to_string cell =
  Format.asprintf "%a" Wax_lang.Infer.output_inferred_type cell

(* A node's result types as a tooltip string, or [None] when there is nothing
   worth showing: a statement (no value) and a fully unknown / error node (every
   cell unknown or error) are suppressed, so hovering them stays quiet rather
   than popping up [()] or [any]. Otherwise it is the bare type for a single
   value and a parenthesized tuple for several. Types render the way diagnostics
   do — flexible literals as [number]/[int], unresolved as [any], anonymous
   composite types inline — via [output_inferred_type]. *)
let render_result_types
    (tys : Wax_lang.Infer.inferred_type Wax_lang.Infer.Cell.t array) =
  match Array.to_list tys with
  | [] -> None
  | l when List.for_all Wax_lang.Infer.is_unknown_or_error l -> None
  | [ t ] -> Some (cell_to_string t)
  | l -> Some ("(" ^ String.concat ", " (List.map cell_to_string l) ^ ")")

(* Map an incoming VS Code position to a byte column for comparison with Lexing
   columns: the byte column on zero-based [line] that its UTF-16 [char] denotes.
   The inverse of [js_position]'s column conversion. *)
let byte_column src line char =
  let len = String.length src in
  let rec line_start i n =
    if n <= 0 || i >= len then i
    else line_start (i + 1) (if src.[i] = '\n' then n - 1 else n)
  in
  let start = line_start 0 line in
  let stop =
    match String.index_from_opt src start '\n' with Some j -> j | None -> len
  in
  Wax_utils.Unicode.utf16_offset_to_byte
    (String.sub src start (stop - start))
    char

let slice src (loc : Wax_utils.Ast.location) =
  String.sub src loc.loc_start.pos_cnum
    (loc.loc_end.pos_cnum - loc.loc_start.pos_cnum)

(* Render what a name reference resolves to (recorded by the typer as data, so
   only the one hovered is ever formatted): a variable's type, or a referenced
   type's definition ([name] is the referenced type's own name, needed to render
   [type name = …]). *)
let render_hover_target ~name = function
  | Wax_lang.Typing.Value_type ity ->
      cell_to_string (Wax_lang.Infer.valtype_cell ity)
  | Wax_lang.Typing.Type_def st ->
      let field = Wax_lang.Ast.no_loc (Wax_lang.Ast.no_loc name, st) in
      let buf = Buffer.create 64 in
      let fmt = Format.formatter_of_buffer buf in
      Wax_utils.Printer.run ~width:Wax_lang.Output.width fmt (fun p ->
          Wax_lang.Output.subtype p field);
      Format.pp_print_flush fmt ();
      String.trim (Buffer.contents buf)

let hover_string src line ch =
  let a = analyze src in
  (* Lexing lines are one-based and its columns are byte offsets; [ch] is a
     zero-based UTF-16 column, so convert it against the buffer. *)
  let target = (line + 1, byte_column src line ch) in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  let contains (loc : Wax_utils.Ast.location) =
    le (pos loc.loc_start) target && le target (pos loc.loc_end)
  in
  let span (loc : Wax_utils.Ast.location) =
    loc.loc_end.Lexing.pos_cnum - loc.loc_start.pos_cnum
  in
  (* The innermost expression node under the cursor and its rendered type. Track
     the smallest span containing the cursor; a child's span is contained in its
     parent's, so the smallest is the innermost node. Renders [None] for a
     statement / unknown node, so those stay quiet. *)
  let expression =
    match a.a_typed with
    | None -> None
    | Some typed ->
        let best = ref None in
        let observe ((tys, loc) : Wax_lang.Typing.inferred_module_annotation) =
          (if contains loc then
             match !best with
             | Some (best_loc, _) when span best_loc <= span loc -> ()
             | _ -> best := Some (loc, tys));
          (tys, loc)
        in
        List.iter
          (fun (field :
                 ( Wax_lang.Typing.inferred_module_annotation
                   Wax_lang.Ast.modulefield,
                   Wax_utils.Ast.location )
                 Wax_lang.Ast.annotated) ->
            ignore (Wax_lang.Ast_utils.map_modulefield observe field.desc))
          typed;
        Option.bind !best (fun (loc, tys) ->
            Option.map (fun h_type -> (loc, h_type)) (render_result_types tys))
  in
  (* The smallest name reference covering the cursor (a type reference, an
     assignment target, a bare global): a name that is usually not an expression
     node. *)
  let reference =
    List.fold_left
      (fun best (r : Wax_lang.Typing.reference) ->
        match r.hover with
        | Some tgt when contains r.use -> (
            match best with
            | Some (bloc, _) when span bloc <= span r.use -> best
            | _ -> Some (r.use, tgt))
        | _ -> best)
      None a.a_defs
  in
  (* An identifier reference is more specific than the expression enclosing it,
     so the smaller span wins; a tie prefers the reference — e.g. the type name
     in [e as &t] resolves to the type, not the cast's result. *)
  match (expression, reference) with
  | Some (eloc, h_type), Some (rloc, _) when span eloc < span rloc ->
      Some { h_type; h_range = eloc }
  | _, Some (rloc, tgt) ->
      Some
        {
          h_type = render_hover_target ~name:(slice src rloc) tgt;
          h_range = rloc;
        }
  | Some (eloc, h_type), None -> Some { h_type; h_range = eloc }
  | None, None -> None

(* Inlay hints (Wax only): the inferred type on each un-annotated [let] binding,
   so [let x = 3] shows a virtual [: i32] after [x]. Reads the same cached cell
   tree as hover; a binding's type is the corresponding result of its
   initializer. Skipped: a binding the user already annotated ([let x: i32 =]),
   the discard binding ([_ = e], no name), and one whose type is unknown/error.
   The hint sits at the identifier's end, where the [: type] would be written. *)
type inlay = { n_pos : Lexing.position; n_label : string }

let inlays_string src =
  match (analyze src).a_typed with
  | None -> []
  | Some typed ->
      let hints = ref [] in
      let visit
          (i : Wax_lang.Typing.inferred_module_annotation Wax_lang.Ast.instr) =
        match i.desc with
        | Wax_lang.Ast.Let (bindings, Some init) ->
            let cells, _ = init.info in
            List.iteri
              (fun idx (id_opt, vt_opt) ->
                match (id_opt, vt_opt) with
                | Some id, None
                  when idx < Array.length cells
                       && not (Wax_lang.Infer.is_unknown_or_error cells.(idx))
                  ->
                    let loc : Wax_utils.Ast.location = id.Wax_lang.Ast.info in
                    hints :=
                      {
                        n_pos = loc.loc_end;
                        n_label = ": " ^ cell_to_string cells.(idx);
                      }
                      :: !hints
                | _ -> ())
              bindings
        | _ -> ()
      in
      Wax_lang.Ast_utils.iter_module_instr visit typed;
      List.rev !hints

(* Go-to-definition (Wax only): the definition span(s) for the name or label use
   under the cursor. [analyze] records every resolved reference (use span ->
   definition spans) while type-checking; find the innermost use span covering
   the position and return its definitions — usually one, several only for a name
   defined in multiple conditional-compilation branches. *)
let definition_string src line ch =
  let target = (line + 1, byte_column src line ch) in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  let best =
    List.fold_left
      (fun best (r : Wax_lang.Typing.reference) ->
        let loc = r.use in
        if le (pos loc.loc_start) target && le target (pos loc.loc_end) then
          let span = loc.loc_end.Lexing.pos_cnum - loc.loc_start.pos_cnum in
          match best with
          | Some (best_span, _) when best_span <= span -> best
          | _ -> Some (span, r.definitions)
        else best)
      None (analyze src).a_defs
  in
  match best with None -> [] | Some (_, defs) -> defs

(* Find-references / document-highlight (Wax only): every occurrence of the
   symbol under the cursor — its definition(s) and all uses that resolve to
   them — for "Find All References" and highlighting the symbol in the document.
   The cursor identifies the symbol whether it sits on a use (take that
   reference's definitions) or on a definition itself (take that def span); then
   collect every reference sharing a target definition, plus the targets. Both
   consumers get the same set, since every occurrence is in this document. *)
let same_span (a : Wax_utils.Ast.location) (b : Wax_utils.Ast.location) =
  a.loc_start.Lexing.pos_cnum = b.loc_start.pos_cnum
  && a.loc_end.pos_cnum = b.loc_end.pos_cnum

let references_string src line ch =
  let refs = (analyze src).a_defs in
  let target = (line + 1, byte_column src line ch) in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  let contains (loc : Wax_utils.Ast.location) =
    le (pos loc.loc_start) target && le target (pos loc.loc_end)
  in
  (* The definition span(s) the cursor picks out: from a use it sits on, or a
     definition it sits on directly. *)
  let targets =
    List.concat_map
      (fun (r : Wax_lang.Typing.reference) ->
        (if contains r.use then r.definitions else [])
        @ List.filter contains r.definitions)
      refs
  in
  if targets = [] then []
  else
    let is_target loc = List.exists (same_span loc) targets in
    let uses =
      List.filter_map
        (fun (r : Wax_lang.Typing.reference) ->
          if List.exists is_target r.definitions then Some r.use else None)
        refs
    in
    (* The definitions and every use, deduplicated by span (the typer may
       resolve a name more than once). *)
    let seen = Hashtbl.create 16 in
    List.filter
      (fun (l : Wax_utils.Ast.location) ->
        let k = (l.loc_start.Lexing.pos_cnum, l.loc_end.pos_cnum) in
        if Hashtbl.mem seen k then false
        else (
          Hashtbl.add seen k ();
          true))
      (targets @ uses)

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
   one-based. The character is a count of UTF-16 code units, whereas Lexing's
   [pos_cnum - pos_bol] is a byte column — the two differ once a line contains a
   non-ASCII character (Wax allows them in identifiers and comments), so convert
   the line prefix up to the position. [src] is the buffer being indexed. *)
let js_position src (p : Lexing.position) =
  let bol = p.Lexing.pos_bol and cnum = p.Lexing.pos_cnum in
  ( p.Lexing.pos_lnum - 1,
    Wax_utils.Unicode.utf16_length (String.sub src bol (cnum - bol)) )

let js_related src (message, (location : Wax_utils.Ast.location)) =
  let start_line, start_char = js_position src location.loc_start in
  let end_line, end_char = js_position src location.loc_end in
  object%js
    val message = Js.string (String.trim message)
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
  end

let js_diagnostic src d =
  let start_line, start_char = js_position src d.location.loc_start in
  let end_line, end_char = js_position src d.location.loc_end in
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

    val warning =
      match d.warning with Some w -> Js.some (Js.string w) | None -> Js.null

    val hint =
      match d.hint with
      | Some h -> Js.some (Js.string (String.trim h))
      | None -> Js.null

    val related = Js.array (Array.of_list (List.map (js_related src) d.related))
  end

let js_hover src h =
  let start_line, start_char = js_position src h.h_range.loc_start in
  let end_line, end_char = js_position src h.h_range.loc_end in
  object%js
    (* [type_] is exposed to JS as the property [type] (the ppx strips the
       trailing underscore, which lets us use the reserved word). *)
    val type_ = Js.string h.h_type
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
  end

let js_inlay src n =
  let line, char = js_position src n.n_pos in
  object%js
    val line = line
    val char = char
    val label = Js.string n.n_label
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
  let s = Js.to_string src in
  let diagnostics = try check_fn s with _ -> [] in
  Js.array (Array.of_list (List.map (js_diagnostic s) diagnostics))

(* [null] when there is no typed node under the cursor (or anything went wrong):
   the provider then shows no hover rather than crashing the host. *)
let hover_result src line ch =
  let s = Js.to_string src in
  match try hover_string s line ch with _ -> None with
  | None -> Js.null
  | Some h -> Js.some (js_hover s h)

let inlays_result src =
  let s = Js.to_string src in
  let hints = try inlays_string s with _ -> [] in
  Js.array (Array.of_list (List.map (js_inlay s) hints))

(* Each definition as a plain range object; empty array when nothing resolves. *)
let js_range src (loc : Wax_utils.Ast.location) =
  let start_line, start_char = js_position src loc.loc_start in
  let end_line, end_char = js_position src loc.loc_end in
  object%js
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
  end

let definition_result src line ch =
  let s = Js.to_string src in
  let defs = try definition_string s line ch with _ -> [] in
  Js.array (Array.of_list (List.map (js_range s) defs))

let references_result src line ch =
  let s = Js.to_string src in
  let occurrences = try references_string s line ch with _ -> [] in
  Js.array (Array.of_list (List.map (js_range s) occurrences))

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

(* The outline is built with panic-mode recovery too, so a buffer with a syntax
   error still shows the items around it (the whole file used to collapse to an
   empty outline at the first error). The syntax errors themselves are ignored
   here — [check] reports them — and the intact top-level items of the
   best-effort AST are outlined; only those dropped during recovery are missing.
   No type-checking, so recovery mode does not matter. *)
let symbols_string src =
  let ast_opt, _syntax_errors, _ctx =
    Wax_parser.parse_recover ~filename:"<buffer>" ~sync:Wax_lang.Recover.sync
      ~insert:Wax_lang.Recover.insert ~closers:Wax_lang.Recover.closers src
  in
  match ast_opt with
  | None -> []
  | Some ast -> List.concat_map field_symbols ast

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
  let import_kind (desc : importdesc) =
    match desc with
    | Func _ -> "function"
    | Memory _ -> "memory"
    | Table _ -> "table"
    | Global _ -> "variable"
    | Tag _ -> "event"
  in
  let import_sym module_ (name : name) (id : name option) desc =
    let s_name, s_selection =
      match id with
      | Some n -> (id_name n, n.info)
      | None -> (module_ ^ "." ^ name.desc, name.info)
    in
    one s_name (import_kind desc) s_selection
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
      [ import_sym module_.desc name id desc ]
  | Import_group1 { module_; items } ->
      List.map
        (fun (name, id, desc) -> import_sym module_.desc name id desc)
        items
  | Import_group2 { module_; desc; items } ->
      List.map (fun (name, id) -> import_sym module_.desc name id desc) items
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

let rec js_symbol src s =
  let start_line, start_char = js_position src s.s_range.loc_start in
  let end_line, end_char = js_position src s.s_range.loc_end in
  let sel_start_line, sel_start_char =
    js_position src s.s_selection.loc_start
  in
  let sel_end_line, sel_end_char = js_position src s.s_selection.loc_end in
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

    val children =
      Js.array (Array.of_list (List.map (js_symbol src) s.s_children))
  end

let symbols_result symbols_fn src =
  let s = Js.to_string src in
  let syms = try symbols_fn s with _ -> [] in
  Js.array (Array.of_list (List.map (js_symbol s) syms))

let () =
  Js.export "wax"
    object%js
      method format src = format_result format_string src
      method check src = check_result check_string src
      method hover src line ch = hover_result src line ch
      method inlays src = inlays_result src
      method definition src line ch = definition_result src line ch
      method references src line ch = references_result src line ch
      method symbols src = symbols_result symbols_string src
      method formatWat src = format_result format_wat_string src
      method checkWat src = check_result check_wat_string src
      method symbolsWat src = symbols_result symbols_wat_string src
      method toWat src = format_result to_wat_string src
      method toWax src = format_result to_wax_string src
    end
