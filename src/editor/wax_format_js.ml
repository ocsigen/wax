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
   - [renamePrepare src line ch] -> { startLine; startChar; endLine; endChar } or
     null: the span of the renameable symbol at the position, or null if there is
     none (the editor then declines to rename). Wax only.
   - [rename src line ch newname] -> array of { startLine; startChar; endLine;
     endChar; newText }: the edits to rename the symbol at the position to
     [newname] — every occurrence, with a punned field expanded to [x: newname].
     Wax only.
   - [symbols src] / [symbolsWat src] -> the module's top-level definitions, for
     the outline.
   - [completion src line ch] -> array of { name; kind; detail }: completion
     candidates at the (zero-based) position. After [recv.] (a member access),
     the receiver's members — a struct's fields, or the value methods of a
     numeric / v128 / memory / table receiver; after [ns::], the intrinsic
     namespace's free functions; otherwise the names in scope — the module's
     top-level definitions, the enclosing function's parameters and the locals
     bound before the cursor, the keywords, and the intrinsic namespace names.
     [detail] is a one-line type / signature (empty when none). The editor
     filters by the typed prefix. Wax only.
   - [signatureHelp src line ch] -> { label; parameters; active } or null: the
     enclosing call's signature at the (zero-based) position — [label] the
     callee's rendered signature, [parameters] the [start, end) offset of each
     parameter within it, [active] the argument index the cursor is on. Found
     from the innermost [Call] node containing the cursor in the typed tree, so
     a method call's receiver type is available: it covers a named function or
     import, an [ns::] intrinsic, and a method ([x.min(_)], [mem.load8(_)]) whose
     signature comes from the receiver's inferred type. Error recovery
     auto-closes a call still being typed (an unclosed [f(1,] or a bare [f(]), so
     it works mid-edit, not only when the parentheses are balanced. Wax only.
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
  a_puns : Wax_utils.Ast.location list;
      (* punned struct-literal field spans, which rename must expand. *)
  a_members : (Wax_utils.Ast.location * Wax_lang.Typing.member_receiver) list;
      (* at each member access, the field span and what the receiver is (a
         struct, a numeric / v128 value, a memory / table), for member
         completion; the candidate list is derived on demand. *)
}

let analyze_uncached src =
  let ast_opt, syntax_errors, _ctx =
    Wax_parser.parse_recover ~filename:"<buffer>" ~sync:Wax_lang.Recover.sync
      ~insert:Wax_lang.Recover.insert ~closers:Wax_lang.Recover.closers src
  in
  let a_syntax = List.map syntax_error_diag syntax_errors in
  match ast_opt with
  | None ->
      {
        a_syntax;
        a_type = [];
        a_typed = None;
        a_defs = [];
        a_puns = [];
        a_members = [];
      }
  | Some ast ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      Wax_utils.Diagnostic.set_recovery d (syntax_errors <> []);
      (* [f_infer] may abort mid-pass; the diagnostics it collected up to that
         point still stand (as with [check] before), so read [d] regardless. It
         emits the same diagnostics as [f]/[check] but keeps the inference cells
         (which hover renders via [Infer.output_inferred_type]) and, given a
         sink, records the use -> definition references go-to-definition needs. *)
      let links = ref [] in
      let puns = ref [] in
      let members = ref [] in
      let a_typed =
        try
          Some
            (snd
               (Wax_lang.Typing.f_infer ~warn_unused:true
                  ~resolve_links:(Some links) ~pun_spans:(Some puns)
                  ~member_completions:(Some members) d ast))
        with Wax_utils.Diagnostic.Aborted -> None
      in
      {
        a_syntax;
        a_type = collected_diags d;
        a_typed;
        a_defs = !links;
        a_puns = !puns;
        a_members = !members;
      }

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

(* Rename (Wax only). The occurrences are exactly find-references; each is
   replaced with the new name, except a punned struct field (the bare-name form
   [x] for [x: x]), whose span is the field name, is expanded to [x: new] so
   renaming the variable does not silently rename the field. Returns
   [(span, replacement)] edits, empty when the cursor is not on a renameable
   symbol — the provider then declines. *)
let occurrence_at src line ch (loc : Wax_utils.Ast.location) =
  let target = (line + 1, byte_column src line ch) in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  le (pos loc.loc_start) target && le target (pos loc.loc_end)

(* The span of the token to rename (for the editor's prepare step), or [None]
   when the cursor is not on a renameable symbol. *)
let rename_prepare_string src line ch =
  List.find_opt (occurrence_at src line ch) (references_string src line ch)

let rename_string src line ch newname =
  let puns = (analyze src).a_puns in
  List.map
    (fun (loc : Wax_utils.Ast.location) ->
      let replacement =
        if List.exists (same_span loc) puns then slice src loc ^ ": " ^ newname
        else newname
      in
      (loc, replacement))
    (references_string src line ch)

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

(* [null] when the cursor is not on a renameable symbol; the provider then
   reports that rename is not available here. *)
let rename_prepare_result src line ch =
  let s = Js.to_string src in
  match try rename_prepare_string s line ch with _ -> None with
  | None -> Js.null
  | Some loc -> Js.some (js_range s loc)

let js_edit src (loc, newText) =
  let start_line, start_char = js_position src loc.Wax_utils.Ast.loc_start in
  let end_line, end_char = js_position src loc.loc_end in
  object%js
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
    val newText = Js.string newText
  end

let rename_result src line ch newname =
  let s = Js.to_string src in
  let n = Js.to_string newname in
  let edits = try rename_string s line ch n with _ -> [] in
  Js.array (Array.of_list (List.map (js_edit s) edits))

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

(* Completion (Wax only). After [name.] (a struct field access), the receiver
   struct's field names — recorded by the typer, which the improved parser
   recovery lets it resolve even from the half-written access. Otherwise, off the
   recovered parse alone (no typing, so ordinary completion stays cheap): the
   module's top-level names (reusing the outline walk), the parameters and [let]
   locals of the function the cursor is in, and the keywords. The editor filters
   by the typed prefix, so every candidate is offered. Precise per-point local
   scoping is a follow-up. *)
(* [k_detail] is a one-line type / signature shown beside the item, or "". *)
type completion = { k_name : string; k_kind : string; k_detail : string }

(* The keywords come from [Wax_conversion.Namespace.reserved_words], the single
   list the keyword-consistency test keeps in step with the lexer, so this never
   drifts. *)
let wax_keywords = Wax_conversion.Namespace.reserved_words

(* Render a declaration's type / signature for a completion item's detail,
   straight from the parsed AST (no typing). A wide margin keeps it on one
   line. *)
let render_wax f =
  let buf = Buffer.create 32 in
  let fmt = Format.formatter_of_buffer buf in
  Wax_utils.Printer.run ~width:1_000_000 fmt f;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let render_valtype vt = render_wax (fun p -> Wax_lang.Output.valtype p vt)
let render_typedef entry = render_wax (fun p -> Wax_lang.Output.subtype p entry)

let render_signature typ (sign : Wax_lang.Ast.functype option) =
  let open Wax_lang.Ast in
  match sign with
  | Some { params; results } -> (
      let param p =
        match p.desc with
        | Some (id : ident), vt -> id.desc ^ ": " ^ render_valtype vt
        | None, vt -> render_valtype vt
      in
      let ps = List.map param (Array.to_list params) in
      let rs = List.map render_valtype (Array.to_list results) in
      "fn(" ^ String.concat ", " ps ^ ")"
      ^ match rs with [] -> "" | _ -> " -> " ^ String.concat ", " rs)
  | None -> ( match typ with Some (t : ident) -> "fn " ^ t.desc | None -> "")

let import_completion
    (decl :
      (Wax_lang.Ast.import_decl, Wax_utils.Ast.location) Wax_lang.Ast.annotated)
    =
  let open Wax_lang.Ast in
  let d = decl.desc in
  let detail =
    match d.kind with
    | Import_func { sign; typ; _ } -> render_signature typ sign
    | Import_global { typ; _ } -> render_valtype typ
    | Import_tag { sign; _ } -> render_signature None sign
    | Import_memory _ | Import_table _ -> ""
  in
  { k_name = d.id.desc; k_kind = import_kind_str d.kind; k_detail = detail }

(* A module field's completion candidates: its name(s), kind, and a detail
   rendered from the declaration. Mirrors [field_symbols] (the outline) but
   carries the type; an import group contributes its members. *)
let field_completions
    (field :
      ( Wax_lang.Ast.location Wax_lang.Ast.modulefield,
        Wax_utils.Ast.location )
      Wax_lang.Ast.annotated) : completion list =
  let open Wax_lang.Ast in
  let one k_name k_kind k_detail = { k_name; k_kind; k_detail } in
  match field.desc with
  | Func { name; typ; sign; _ } ->
      [ one name.desc "function" (render_signature typ sign) ]
  | Global { name; typ; _ } ->
      [
        one name.desc "variable"
          (match typ with Some vt -> render_valtype vt | None -> "");
      ]
  | Tag { name; sign; _ } ->
      [ one name.desc "event" (render_signature None sign) ]
  | Type rectype ->
      Array.to_list rectype
      |> List.map (fun entry ->
          let id, _ = entry.desc in
          one id.desc "type" (render_typedef entry))
  | Memory { name; _ } -> [ one name.desc "memory" "" ]
  | Table { name; _ } -> [ one name.desc "table" "" ]
  | Elem { name; _ } -> [ one name.desc "array" "" ]
  | Data { name = Some n; _ } -> [ one n.desc "data" "" ]
  | Data { name = None; _ } -> []
  | Import { decl; _ } -> [ import_completion decl ]
  | Import_group { decls; _ } -> List.map import_completion decls
  | Module_annotation _ | Conditional _ -> []

(* Parameters and the [let] locals in scope at the cursor, for the function
   whose span covers it: every parameter, plus each [let] bound before the
   cursor in its block or an enclosing block (see [scope] below).
   [iter_fields] descends into conditional branches, so a function defined
   under [#[if]] is found too. *)
let function_locals ast target =
  let open Wax_lang.Ast in
  let contains (loc : Wax_utils.Ast.location) =
    let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
    let pos (p : Lexing.position) =
      (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
    in
    le (pos loc.loc_start) target && le target (pos loc.loc_end)
  in
  let acc = ref [] in
  Wax_lang.Ast_utils.iter_fields
    (fun field ->
      match field.desc with
      | Func { sign; body = _, instrs; _ } when contains field.info ->
          let params =
            match sign with
            | Some { params; _ } ->
                Array.to_list params
                |> List.filter_map (fun p ->
                    match p.desc with
                    | Some id, vt ->
                        Some
                          {
                            k_name = id.desc;
                            k_kind = "parameter";
                            k_detail = render_valtype vt;
                          }
                    | None, _ -> None)
            | None -> []
          in
          (* The [let] locals in scope at the cursor: at each block level, those
             bound before the cursor, descending only into the sub-instruction
             that contains it. A [let] in a sibling block that precedes the
             cursor is not a preceding statement here, so it is not collected;
             the cursor's own enclosing [let] init likewise sees only earlier
             bindings, not itself. *)
          let pos (p : Lexing.position) =
            (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
          in
          let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
          let binding_completions bindings =
            List.filter_map
              (fun (id_opt, vt_opt) ->
                match id_opt with
                | Some id ->
                    Some
                      {
                        k_name = id.desc;
                        k_kind = "local";
                        k_detail =
                          (match vt_opt with
                          | Some vt -> render_valtype vt
                          | None -> "");
                      }
                | None -> None)
              bindings
          in
          let rec scope instrs =
            List.concat_map
              (fun (i : _ Wax_lang.Ast.instr) ->
                if le (pos i.info.loc_end) target then
                  match i.desc with
                  | Let (bindings, _) -> binding_completions bindings
                  | _ -> []
                else if le (pos i.info.loc_start) target then
                  scope (Wax_lang.Ast_utils.sub_instrs i)
                else [])
              instrs
          in
          acc := !acc @ params @ scope instrs
      | _ -> ())
    ast;
  !acc

(* The module-level definitions in scope at the cursor, conditional compilation
   taken into account: each definition is guarded by the [#[if]] arms
   ([Conditional]) enclosing it, and the cursor sits under the [#[if]] arms
   ([Conditional] at module level, [If_annotation] within its function) enclosing
   *it*. A definition is offered only when its guard is satisfiable together with
   the cursor's — so a definition in a branch mutually exclusive with the cursor's
   position (an [#[else]] when the cursor is in the [#[if]], say) is dropped. With
   no conditionals every guard is [true], so all definitions are offered. *)
let module_completions src ast target =
  let open Wax_lang.Ast in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  let contains (loc : Wax_utils.Ast.location) =
    le (pos loc.loc_start) target && le target (pos loc.loc_end)
  in
  let env = Wax_wasm.Cond_solver.create () in
  let dctx = Wax_utils.Diagnostic.collector ~source:src () in
  let formula loc c = Wax_wasm.Cond_solver.of_cond env dctx ~location:loc c in
  let ( &&& ) = Wax_wasm.Cond_solver.and_ in
  let neg = Wax_wasm.Cond_solver.not_ in
  (* The cursor's path condition. *)
  let ctx = ref Wax_wasm.Cond_solver.true_ in
  let add loc c pol =
    let f = formula loc c in
    ctx := !ctx &&& if pol then f else neg f
  in
  let rec ctx_instr i =
    match i.desc with
    | If_annotation { cond; then_body; else_body } -> (
        if contains then_body.info then (
          add i.info cond true;
          List.iter ctx_instr then_body.desc)
        else
          match else_body with
          | Some b when contains b.info ->
              add i.info cond false;
              List.iter ctx_instr b.desc
          | _ -> ())
    | _ ->
        List.iter
          (fun c -> if contains c.info then ctx_instr c)
          (Wax_lang.Ast_utils.sub_instrs i)
  in
  let rec ctx_fields fields =
    List.iter
      (fun field ->
        match field.desc with
        | Conditional { cond; then_fields; else_fields } -> (
            if contains then_fields.info then (
              add field.info cond true;
              ctx_fields then_fields.desc)
            else
              match else_fields with
              | Some b when contains b.info ->
                  add field.info cond false;
                  ctx_fields b.desc
              | _ -> ())
        | Func { body = _, instrs; _ } when contains field.info ->
            List.iter ctx_instr instrs
        | _ -> ())
      fields
  in
  ctx_fields ast;
  (* Each definition with the module condition guarding it, kept when compatible
     with the cursor's path condition. *)
  let rec defs guard fields =
    List.concat_map
      (fun field ->
        match field.desc with
        | Conditional { cond; then_fields; else_fields } ->
            let f = formula field.info cond in
            defs (guard &&& f) then_fields.desc
            @ Option.fold ~none:[]
                ~some:(fun b -> defs (guard &&& neg f) b.desc)
                else_fields
        | _ -> List.map (fun c -> (c, guard)) (field_completions field))
      fields
  in
  defs Wax_wasm.Cond_solver.true_ ast
  |> List.filter_map (fun (c, guard) ->
      if Wax_wasm.Cond_solver.is_satisfiable (!ctx &&& guard) then Some c
      else None)

let is_ident_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_'
  || Char.code c >= 128

let line_start_offset src line =
  let len = String.length src in
  let rec f i n =
    if n <= 0 || i >= len then i
    else f (i + 1) (if src.[i] = '\n' then n - 1 else n)
  in
  f 0 line

(* Whether the cursor is completing a struct field: it follows [name.] — an
   identifier prefix (possibly empty) whose preceding non-identifier character is
   a [.]. A cheap text test, so ordinary name completion never runs the typed
   pass member completion needs. *)
let is_member_position src line ch =
  let off = line_start_offset src line + byte_column src line ch in
  let i = ref (off - 1) in
  while !i >= 0 && is_ident_char src.[!i] do
    decr i
  done;
  !i >= 0 && src.[!i] = '.'

(* The receiver of the member access whose (possibly partial) field span covers
   the cursor in [members], if any. *)
let member_receiver_at src line ch members =
  let target = (line + 1, byte_column src line ch) in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  List.find_map
    (fun ((loc : Wax_utils.Ast.location), receiver) ->
      if le (pos loc.loc_start) target && le target (pos loc.loc_end) then
        Some receiver
      else None)
    members

let member_completion (c : Wax_lang.Typing.member_candidate) =
  {
    k_name = c.member_name;
    k_kind =
      (match c.member_kind with
      | Field -> "field"
      | Method -> "method"
      | Function -> "function");
    k_detail = c.member_detail;
  }

(* If the cursor is completing an intrinsic namespace path — it follows [ns::]
   with an identifier prefix (possibly empty), where [ns] is an identifier and
   [::] immediately precedes the prefix — the namespace name [ns]. A text test,
   like {!is_member_position}: the [::] operator only introduces a namespace
   path, so name completion never belongs here. *)
let namespace_position src line ch =
  let off = line_start_offset src line + byte_column src line ch in
  let i = ref (off - 1) in
  while !i >= 0 && is_ident_char src.[!i] do
    decr i
  done;
  (* [!i] now indexes the char before the (possibly empty) member prefix. *)
  if !i >= 1 && src.[!i] = ':' && src.[!i - 1] = ':' then (
    let j = ref (!i - 2) in
    let stop = !j in
    while !j >= 0 && is_ident_char src.[!j] do
      decr j
    done;
    if !j < stop then Some (String.sub src (!j + 1) (stop - !j)) else None)
  else None

let completion_string src line ch =
  if is_member_position src line ch then
    match member_receiver_at src line ch (analyze src).a_members with
    | Some r -> List.map member_completion (Wax_lang.Typing.member_candidates r)
    | None -> (
        (* A bare [.]: the parser drops the field-less access, so nothing is
           recorded. Splice a sentinel field in so [recv.<sentinel>] parses and
           types, then read the receiver's fields at the sentinel (analyzed
           uncached, so the transient buffer does not evict the real one). *)
        let off = line_start_offset src line + byte_column src line ch in
        let sentinel = "waxCompletionProbe" in
        let repaired =
          String.sub src 0 off ^ sentinel
          ^ String.sub src off (String.length src - off)
        in
        match
          member_receiver_at repaired line ch
            (analyze_uncached repaired).a_members
        with
        | Some r ->
            List.map member_completion (Wax_lang.Typing.member_candidates r)
        | None -> [])
  else
    match namespace_position src line ch with
    | Some ns ->
        (* After [ns::]: the intrinsic namespace's free functions, known
           textually (the namespaces are keywords), so this needs no parse. *)
        List.map member_completion (Wax_lang.Typing.namespace_members ns)
    | None -> (
        let target = (line + 1, byte_column src line ch) in
        let ast_opt, _syntax_errors, _ctx =
          Wax_parser.parse_recover ~filename:"<buffer>"
            ~sync:Wax_lang.Recover.sync ~insert:Wax_lang.Recover.insert
            ~closers:Wax_lang.Recover.closers src
        in
        let keywords =
          List.map
            (fun k -> { k_name = k; k_kind = "keyword"; k_detail = "" })
            wax_keywords
        in
        (* The intrinsic namespace names, so [v128::] / [i64::] / [atomic::] is
           discoverable; selecting one leaves the cursor before the [::]. *)
        let namespaces =
          List.map
            (fun n ->
              {
                k_name = n;
                k_kind = "namespace";
                k_detail = "intrinsic namespace";
              })
            Wax_lang.Typing.intrinsic_namespaces
        in
        match ast_opt with
        | None -> keywords @ namespaces
        | Some ast ->
            (* The module's definitions in scope at the cursor (descending into
               conditional branches, but dropping ones a mutually-exclusive
               [#[if]] arm guards; see [module_completions]). *)
            let module_ = module_completions src ast target in
            let locals = function_locals ast target in
            (* Locals shadow module names of the same name; keep the first
           occurrence of each (name, kind). *)
            let seen = Hashtbl.create 64 in
            List.filter
              (fun c ->
                let k = (c.k_name, c.k_kind) in
                if Hashtbl.mem seen k then false
                else (
                  Hashtbl.add seen k ();
                  true))
              (locals @ module_ @ keywords @ namespaces))

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

(* The signature label of the callee of a call [callee(args)], for signature
   help: a named function ([Get name], defined or imported) rendered as
   [fn(a: i32) -> i32], or an intrinsic namespace path ([ns::name]) from its
   registered signature. [None] for a method call (see [method_label]) or an
   unknown callee. *)
let callee_label ast callee =
  let open Wax_lang.Ast in
  match callee.desc with
  | Get name ->
      let found = ref None in
      let consider (decl : import_decl) =
        match decl with
        | { id; kind = Import_func { sign; typ; _ }; _ }
          when id.desc = name.desc ->
            found := Some (render_signature typ sign)
        | _ -> ()
      in
      Wax_lang.Ast_utils.iter_fields
        (fun field ->
          if Option.is_none !found then
            match field.desc with
            | Func { name = n; sign; typ; _ } when n.desc = name.desc ->
                found := Some (render_signature typ sign)
            | Import { decl; _ } -> consider decl.desc
            | Import_group { decls; _ } ->
                List.iter (fun d -> consider d.desc) decls
            | _ -> ())
        ast;
      !found
  | Path (ns, nm) ->
      List.find_map
        (fun (c : Wax_lang.Typing.member_candidate) ->
          if c.member_name = nm.desc then Some c.member_detail else None)
        (Wax_lang.Typing.namespace_members ns.desc)
  | _ -> None

let addr_type_name : [ `I32 | `I64 ] -> string = function
  | `I32 -> "i32"
  | `I64 -> "i64"

(* The element type of the array type named [name] in the module (its [type
   name = [elem]] definition), for resolving an array receiver's methods. *)
let array_element typed_module name =
  let found = ref None in
  Wax_lang.Ast_utils.iter_fields
    (fun field ->
      match field.Wax_lang.Ast.desc with
      | Wax_lang.Ast.Type rectype ->
          Array.iter
            (fun entry ->
              let id, (sub : Wax_lang.Ast.subtype) = entry.Wax_lang.Ast.desc in
              if id.Wax_lang.Ast.desc = name then
                match sub.typ with Array elem -> found := Some elem | _ -> ())
            rectype
      | _ -> ())
    typed_module;
  !found

(* The signature label of a method call [recv.meth(...)], for signature help. The
   candidate signatures of [recv] are those of a memory / table it names (by the
   declared address / element type from the module) or, otherwise, the value
   methods of its inferred type — read from the typed tree, [fst recv.info], the
   receiver's result cells. The one named [meth] gives the label. *)
let method_label typed_module recv meth_name =
  let open Wax_lang.Ast in
  let value () =
    let cells = fst recv.info in
    if Array.length cells = 0 then None
    else
      let ty = Wax_lang.Infer.Cell.get cells.(Array.length cells - 1) in
      match ty with
      | Wax_lang.Infer.Valtype { typ = Ref { typ = Type n | Exact n; _ }; _ }
        -> (
          (* an array receiver: its element type selects the array methods *)
          match array_element typed_module n.desc with
          | Some elem -> Some (Wax_lang.Typing.array_method_candidates elem)
          | None -> Wax_lang.Typing.numeric_receiver_candidates ty)
      | _ -> Wax_lang.Typing.numeric_receiver_candidates ty
  in
  let candidates =
    match recv.desc with
    | Get name -> (
        let obj = ref None in
        Wax_lang.Ast_utils.iter_fields
          (fun field ->
            match field.desc with
            | Memory { name = n; address_type; _ } when n.desc = name.desc ->
                obj := Some (`Mem address_type)
            | Table { name = n; address_type; reftype; _ }
              when n.desc = name.desc ->
                obj := Some (`Tab (address_type, reftype))
            | _ -> ())
          typed_module;
        match !obj with
        | Some (`Mem at) ->
            Some
              (Wax_lang.Typing.memory_method_candidates
                 ~addr_name:(addr_type_name at))
        | Some (`Tab (at, rt)) ->
            Some
              (Wax_lang.Typing.table_method_candidates
                 ~addr_name:(addr_type_name at)
                 ~elem_name:(render_valtype (Ref rt)))
        | None -> value ())
    | _ -> value ()
  in
  Option.bind candidates
    (List.find_map (fun (c : Wax_lang.Typing.member_candidate) ->
         if c.member_name = meth_name then Some c.member_detail else None))

(* The [start, end) offsets of each top-level parameter within a rendered
   [fn(<params>) -> …] label — the region between the outer parentheses, split
   at depth-1 commas (so a function-typed parameter's own [(…)] is not split).
   Used to highlight the active parameter. *)
let param_ranges label =
  let n = String.length label in
  match String.index_opt label '(' with
  | Some lp when lp + 1 < n && label.[lp + 1] <> ')' ->
      let rec scan i depth start acc =
        if i >= n then List.rev acc
        else
          match label.[i] with
          | '(' -> scan (i + 1) (depth + 1) start acc
          | ')' when depth = 1 -> List.rev ((start, i) :: acc)
          | ')' -> scan (i + 1) (depth - 1) start acc
          | ',' when depth = 1 -> scan (i + 2) depth (i + 2) ((start, i) :: acc)
          | _ -> scan (i + 1) depth start acc
      in
      scan (lp + 1) 1 (lp + 1) []
  | _ -> []

(* Signature help at the cursor: the innermost call whose parenthesised span
   contains it, rendered as a label with the source offsets of each parameter
   and the active-parameter index (the number of arguments that end before the
   cursor). Read from the typed tree ([analyze]'s [a_typed]) so a method call's
   receiver type is available; a function / namespace callee needs only its
   name. [None] when the cursor is in no call, or the callee has no known
   signature. Needs the call to parse and type — a balanced (auto-closed) one
   does. *)
let signature_help_string src line ch =
  match (analyze src).a_typed with
  | None -> None
  | Some ast -> (
      let cursor = line_start_offset src line + byte_column src line ch in
      let loc_of (i : _ Wax_lang.Ast.instr) : Wax_utils.Ast.location =
        snd i.info
      in
      let contains i =
        let l = loc_of i in
        l.loc_start.pos_cnum <= cursor && cursor <= l.loc_end.pos_cnum
      in
      (* the innermost (smallest-span) call containing the cursor *)
      let best = ref None in
      Wax_lang.Ast_utils.iter_module_instr
        (fun i ->
          match i.desc with
          | Wax_lang.Ast.Call (callee, args) when contains i -> (
              let l = loc_of i in
              let size = l.loc_end.pos_cnum - l.loc_start.pos_cnum in
              match !best with
              | Some (sz, _, _) when sz <= size -> ()
              | _ -> best := Some (size, callee, args))
          | _ -> ())
        ast;
      match !best with
      | None -> None
      | Some (_, callee, args) -> (
          let label =
            match callee.desc with
            | Wax_lang.Ast.StructGet (recv, meth) ->
                method_label ast recv meth.desc
            | _ -> callee_label ast callee
          in
          match label with
          | None -> None
          | Some label ->
              let ranges = param_ranges label in
              let n = List.length ranges in
              let active =
                List.length
                  (List.filter
                     (fun a -> (loc_of a).loc_end.pos_cnum < cursor)
                     args)
              in
              let active = if n = 0 then 0 else min active (n - 1) in
              Some (label, ranges, active)))

(* A semantic token: 0-based line, 0-based UTF-16 character, UTF-16 length, and
   the token-type name (from the provider legend). *)
type sem_token = {
  st_line : int;
  st_char : int;
  st_len : int;
  st_type : string;
}

(* Map each byte offset in [offsets] (sorted ascending) to its (0-based line,
   0-based UTF-16 column) in [src], in a single left-to-right pass — so the
   whole token list is converted in O(src + offsets) rather than re-scanning a
   line prefix per token (quadratic on a long line). *)
let utf16_positions src offsets =
  let tbl = Hashtbl.create (List.length offsets * 2) in
  let remaining = ref offsets in
  let flush byte line col =
    while match !remaining with o :: _ -> o <= byte | [] -> false do
      match !remaining with
      | o :: rest ->
          Hashtbl.replace tbl o (line, col);
          remaining := rest
      | [] -> ()
    done
  in
  let n = String.length src in
  let byte = ref 0 and line = ref 0 and col = ref 0 in
  while !byte < n && !remaining <> [] do
    flush !byte !line !col;
    let d = String.get_utf_8_uchar src !byte in
    let u = Uchar.utf_decode_uchar d in
    if Uchar.to_int u = Char.code '\n' then (
      incr line;
      col := 0)
    else col := !col + if Uchar.to_int u > 0xFFFF then 2 else 1;
    byte := !byte + max 1 (Uchar.utf_decode_length d)
  done;
  flush !byte !line !col;
  tbl

(* Classify every identifier occurrence for semantic highlighting. The *uses*
   come from the recorded references ([a_defs]): a use is classified by its
   definition's kind, which the structural walk below records — so a `Get` reads
   as a function / variable / parameter, and a type reference (which resolves to
   a type definition) reads as a type, without re-deriving scope here. The
   *definitions* (function / type / variable / parameter names) come from that
   same walk, and struct fields ([property]) and intrinsic namespace paths from a
   pass over the instructions. *)
let semantic_tokens_string src =
  let a = analyze src in
  match a.a_typed with
  | None -> []
  | Some ast ->
      let open Wax_lang.Ast in
      let toks = ref [] in
      let add (loc : Wax_utils.Ast.location) kind =
        toks := (loc, kind) :: !toks
      in
      (* definitions, and each function's parameters and locals *)
      let import_tok = function
        | Import_func _ -> "function"
        | _ -> "variable"
      in
      Wax_lang.Ast_utils.iter_fields
        (fun field ->
          match field.desc with
          | Func { name; sign; body = _, instrs; _ } ->
              add name.info "function";
              (match sign with
              | Some { params; _ } ->
                  Array.iter
                    (fun p ->
                      match p.desc with
                      | Some id, _ -> add id.info "parameter"
                      | None, _ -> ())
                    params
              | None -> ());
              List.iter
                (Wax_lang.Ast_utils.iter_instr (fun i ->
                     match i.desc with
                     | Let (bs, _) ->
                         List.iter
                           (function
                             | Some id, _ -> add id.info "variable"
                             | None, _ -> ())
                           bs
                     | _ -> ()))
                instrs
          | Global { name; _ }
          | Tag { name; _ }
          | Memory { name; _ }
          | Table { name; _ }
          | Elem { name; _ } ->
              add name.info "variable"
          | Data { name = Some n; _ } -> add n.info "variable"
          | Type rectype ->
              Array.iter (fun e -> add (fst e.desc).info "type") rectype
          | Import { decl; _ } ->
              add decl.desc.id.info (import_tok decl.desc.kind)
          | Import_group { decls; _ } ->
              List.iter
                (fun d -> add d.desc.id.info (import_tok d.desc.kind))
                decls
          | Data { name = None; _ } | Module_annotation _ | Conditional _ -> ())
        ast;
      (* struct fields and intrinsic namespace paths, from the instructions *)
      Wax_lang.Ast_utils.iter_module_instr
        (fun i ->
          match i.desc with
          | Path (ns, m) ->
              add ns.info "namespace";
              add m.info "function"
          | StructGet (_, f) | StructSet (_, f, _) -> add f.info "property"
          | Struct (_, fields) | StructDesc (_, fields) ->
              List.iter (fun (id, _) -> add id.info "property") fields
          | _ -> ())
        ast;
      (* uses: classify by the definition's recorded kind *)
      let key (l : Wax_utils.Ast.location) =
        (l.loc_start.pos_cnum, l.loc_end.pos_cnum)
      in
      let kinds = Hashtbl.create 128 in
      List.iter (fun (l, k) -> Hashtbl.replace kinds (key l) k) !toks;
      List.iter
        (fun (r : Wax_lang.Typing.reference) ->
          match r.definitions with
          | d :: _ -> (
              match Hashtbl.find_opt kinds (key d) with
              | Some k -> add r.use k
              | None -> ())
          | [] -> ())
        a.a_defs;
      (* Resolve all byte offsets to UTF-16 positions in one pass (see
         [utf16_positions]), then one token per span, sorted; synthesized
         (negative) spans are dropped. *)
      let toks =
        List.filter
          (fun ((loc : Wax_utils.Ast.location), _) ->
            loc.loc_start.pos_cnum >= 0)
          !toks
      in
      let offsets =
        List.concat_map
          (fun ((loc : Wax_utils.Ast.location), _) ->
            [ loc.loc_start.pos_cnum; loc.loc_end.pos_cnum ])
          toks
        |> List.sort_uniq compare
      in
      let pos = utf16_positions src offsets in
      let seen = Hashtbl.create 256 in
      toks
      |> List.filter_map (fun ((loc : Wax_utils.Ast.location), kind) ->
          match
            ( Hashtbl.find_opt pos loc.loc_start.pos_cnum,
              Hashtbl.find_opt pos loc.loc_end.pos_cnum )
          with
          | Some (line, char), Some (_, ec)
            when not (Hashtbl.mem seen (line, char)) ->
              Hashtbl.add seen (line, char) ();
              Some
                {
                  st_line = line;
                  st_char = char;
                  st_len = ec - char;
                  st_type = kind;
                }
          | _ -> None)
      |> List.sort (fun a b ->
          compare (a.st_line, a.st_char) (b.st_line, b.st_char))

let js_completion c =
  object%js
    val name = Js.string c.k_name
    val kind = Js.string c.k_kind
    val detail = Js.string c.k_detail
  end

let completion_result src line ch =
  let items = try completion_string (Js.to_string src) line ch with _ -> [] in
  Js.array (Array.of_list (List.map js_completion items))

let signature_result src line ch =
  match
    try signature_help_string (Js.to_string src) line ch with _ -> None
  with
  | None -> Js.null
  | Some (label, ranges, active) ->
      Js.Opt.return
        object%js
          val label = Js.string label

          val parameters =
            Js.array
              (Array.of_list
                 (List.map
                    (fun (s, e) ->
                      object%js
                        val startOff = s
                        val endOff = e
                      end)
                    ranges))

          val active = active
        end

let semantic_result src =
  let toks = try semantic_tokens_string (Js.to_string src) with _ -> [] in
  Js.array
    (Array.of_list
       (List.map
          (fun t ->
            object%js
              val line = t.st_line
              val character = t.st_char
              val length = t.st_len
              val kind = Js.string t.st_type
            end)
          toks))

let () =
  Js.export "wax"
    object%js
      method format src = format_result format_string src
      method check src = check_result check_string src
      method hover src line ch = hover_result src line ch
      method inlays src = inlays_result src
      method definition src line ch = definition_result src line ch
      method references src line ch = references_result src line ch
      method renamePrepare src line ch = rename_prepare_result src line ch
      method rename src line ch newname = rename_result src line ch newname
      method symbols src = symbols_result symbols_string src
      method completion src line ch = completion_result src line ch
      method signatureHelp src line ch = signature_result src line ch
      method semanticTokens src = semantic_result src
      method formatWat src = format_result format_wat_string src
      method checkWat src = check_result check_wat_string src
      method symbolsWat src = symbols_result symbols_wat_string src
      method toWat src = format_result to_wat_string src
      method toWax src = format_result to_wax_string src
    end
