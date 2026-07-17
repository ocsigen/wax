(* The Wax toolchain's editor analysis — formatting, checking, and the
   language-server features — as pure functions over Wax source text (the
   Wasm-text counterpart is {!Wat_editor}; the value types the features return
   and the helpers both share are in {!Editor_common}). Two consumers use it:
   [wax_format_js],
   which wraps it for JavaScript (installing [globalThis.wax] under
   wasm_of_ocaml, for the in-process VS Code extension), and [Wax_lsp], which
   drives it from a native LSP server. Every feature is a [*_string] function
   returning a plain OCaml value; the JS marshalling and the LSP protocol
   mapping live in those consumers, not here. Positions are zero-based (line,
   UTF-16 character), the shape both an LSP client and VS Code use. The features:

   - [format src] -> { ok; text; error }: reprint the module with its comments
     preserved (mirrors [wax_to_wax] in bin/main.ml), or report why it could not.
   - [check src] -> array of { severity; message; startLine; startChar; endLine;
     endChar; warning; hint; related }: parse and type-check, returning
     diagnostics for the editor. [warning] is the [-W] name of a lint warning, or
     null.
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
   - [symbols src] -> the module's top-level definitions, for the outline.
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
   - [toWat src] -> { ok; text; error }: compile Wax to Wasm text, for the
     side-by-side preview command ([Wat_editor.to_wax_string] is the reverse).

   Parsing goes through [parse_diagnostics], which yields the AST or a structured
   error without printing or exiting (and without the fast parser), so a syntax
   error becomes an editor squiggle rather than stderr noise. The Wax [check]
   uses [parse_recover] instead, so a buffer with several syntax errors squiggles
   all of them at once rather than only the first. *)

open Editor_common

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

let format_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } ->
      Error (String.trim (Wax_utils.Message.to_plain_string message))
  | Ok (ast, ctx) ->
      let trivia, tail =
        collect_trivia ctx ~print:(fun p ~collect ->
            Wax_lang.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect ast)
      in
      let buf = Buffer.create (String.length src) in
      let fmt = Format.formatter_of_buffer buf in
      let print_wax f m =
        Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
            Wax_lang.Output.module_ p ~trivia ~tail m)
      in
      Format.fprintf fmt "%a@." print_wax ast;
      Ok (Buffer.contents buf)

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
               (Wax_lang.Typing.f_infer ~warn_unused:true ~suggest:true
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

(* The editor's [wax.define] strings parsed into specialization bindings
   (unparseable entries silently dropped), shared by the diagnostics and
   completion paths that specialize to the chosen configuration. *)
let define_bindings defines =
  Wax_wasm.Cond_specialize.of_list
    (List.filter_map
       (fun s ->
         match Wax_wasm.Cond_specialize.parse_define s with
         | Ok b -> Some b
         | Error _ -> None)
       defines)

(* Diagnostics specialized to a chosen conditional-compilation configuration,
   mirroring [wax -D … check]. With no (parseable) defines this is the plain
   [check_string] — the all-configurations path-sensitive check. With defines,
   the [#[if]]/[#[else]] branches the configuration rules out are dropped
   ([Cond_specialize.module_], exactly as [main.ml]'s [specialize_wax] does)
   before type-checking, so a branch that only type-checks under the *other*
   configuration no longer reports errors and the editor's Problems match what a
   [-D] build sees. A partial set leaves the remaining [#[if]]s in place for the
   path-sensitive check. Specialization runs in the same collector as the check,
   so a define used inconsistently (bound as a boolean where a version is
   wanted) still surfaces. Syntax errors are configuration-independent and always
   reported. *)
let check_with_bindings src bindings =
  let ast_opt, syntax_errors, _ctx =
    Wax_parser.parse_recover ~filename:"<buffer>" ~sync:Wax_lang.Recover.sync
      ~insert:Wax_lang.Recover.insert ~closers:Wax_lang.Recover.closers src
  in
  let a_syntax = List.map syntax_error_diag syntax_errors in
  match ast_opt with
  | None -> a_syntax
  | Some ast ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      Wax_utils.Diagnostic.set_recovery d (syntax_errors <> []);
      let ast, _dropped = Wax_lang.Cond_specialize.module_ d bindings ast in
      (try Wax_lang.Typing.check ~warn_unused:true ~suggest:true d ast
       with Wax_utils.Diagnostic.Aborted -> ());
      a_syntax @ collected_diags d

(* Cache the specialized diagnostics keyed by [(source, defines)], mirroring
   [analysis_cache]. The empty-defines path already delegates to the cached
   [check_string], so only the specialized path needs its own cache — but an
   editor's [provideCodeActions] fires on every cursor move with the defines set,
   so without this each move would re-parse and re-type-check the buffer. Same
   size / eviction / exact-key matching as [analysis_cache]. *)
let defines_cache_size = 4
let defines_cache : ((string * string list) * diag list) list ref = ref []

let check_string_with_defines src defines =
  let bindings = define_bindings defines in
  if Wax_wasm.Cond_specialize.is_empty bindings then check_string src
  else
    let key = (src, defines) in
    match List.assoc_opt key !defines_cache with
    | Some d -> d
    | None ->
        let d = check_with_bindings src bindings in
        defines_cache :=
          (key, d)
          :: List.filteri (fun i _ -> i < defines_cache_size - 1) !defines_cache;
        d

(* The quick fixes for a code-action request over the range [(start_line,
   start_char) .. (end_line, end_char)] (each a zero-based (line, character)
   position in [encoding] units, as the editor sends them, specialized to the
   [defines]): every diagnostic carrying a machine-applicable [edit] whose edit
   span — or the diagnostic span it anchors to — meets the request range. Each
   fix is [(title, edit)]: the diagnostic message and the rewrite. The overlap
   filtering lives here so the LSP server and the JS wrapper only convert
   positions and marshal; it is the shared mirror of the VS Code
   [CodeActionProvider]. *)
let code_actions ?(encoding = UTF16) src defines (start_line, start_char)
    (end_line, end_char) =
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  let meets (loc : Wax_utils.Ast.location) =
    let s = position ~encoding src loc.loc_start in
    let e = position ~encoding src loc.loc_end in
    le (start_line, start_char) e && le s (end_line, end_char)
  in
  check_string_with_defines src defines
  |> List.filter_map (fun (d : diag) ->
      match d.edit with
      | None -> None
      | Some edit ->
          if meets edit.edit_location || meets d.location then
            Some (d.message, edit)
          else None)

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

(* Hover types (Wax only). Reads the cell-annotated tree [analyze] built (every
   node's [info] is the inference cells for the values it leaves on the stack,
   paired with its source span), then keeps the smallest span that covers the
   cursor and renders its type — the innermost-node walk an editor hover wants,
   done with the same recursive [map_modulefield] the outline uses. [line]/[ch]
   are the raw zero-based VS Code coordinates ([ch] a UTF-16 column, mapped to a
   byte column by [byte_column]). WAT has no equivalent — its validator builds no
   typed tree. *)
let hover_string ?(encoding = UTF16) src line ch =
  let a = analyze src in
  (* Lexing lines are one-based and its columns are byte offsets; [ch] is a
     zero-based UTF-16 column, so convert it against the buffer. *)
  let target = (line + 1, byte_column ~encoding src line ch) in
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
let definition_string ?(encoding = UTF16) src line ch =
  let target = (line + 1, byte_column ~encoding src line ch) in
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

(* Go-to-type-definition (Wax only): from a value under the cursor, the
   declaration of its *type* — e.g. on a variable of type [&point], jump to
   [type point = { … }]. Distinct from go-to-definition, which jumps to the
   value's own binding. Reads the innermost typed node covering the cursor (like
   hover), takes the named reference type(s) among the values it leaves on the
   stack ([&t] / an exact [&t] — a heap type that is a [Type]/[Exact] index, not
   a primitive or built-in abstract type), and resolves each name to the [type]
   declaration of that name (there may be several under conditional compilation).
   Nothing for a primitive, anonymous, or unknown type. *)
let type_definition_string ?(encoding = UTF16) src line ch =
  let a = analyze src in
  match a.a_typed with
  | None -> []
  | Some typed -> (
      let open Wax_lang.Ast in
      let target = (line + 1, byte_column ~encoding src line ch) in
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
      (* The innermost node covering the cursor that leaves at least one value. *)
      let best = ref None in
      let observe ((tys, loc) : Wax_lang.Typing.inferred_module_annotation) =
        (if contains loc && Array.length tys >= 1 then
           match !best with
           | Some (bloc, _) when span bloc <= span loc -> ()
           | _ -> best := Some (loc, tys));
        (tys, loc)
      in
      List.iter
        (fun field ->
          ignore (Wax_lang.Ast_utils.map_modulefield observe field.desc))
        typed;
      (* Each [type] declaration's name -> the span of that name (descending into
         conditional branches, so a type defined per-configuration is found). *)
      let type_defs = Hashtbl.create 16 in
      Wax_lang.Ast_utils.iter_fields
        (fun field ->
          match (field.desc : _ modulefield) with
          | Type rectype ->
              Array.iter
                (fun elt ->
                  let name_ident, _ = elt.desc in
                  Hashtbl.add type_defs name_ident.desc name_ident.info)
                rectype
          | _ -> ())
        typed;
      (* The name of a value's type when it is a named reference type. *)
      let type_name cell =
        match Wax_lang.Infer.Cell.get cell with
        | Wax_lang.Infer.Valtype { typ = Ref { typ = ht; _ }; _ } -> (
            match (ht : heaptype) with
            | Type idx | Exact idx -> Some idx.desc
            | _ -> None)
        | _ -> None
      in
      match !best with
      | None -> []
      | Some (_, tys) ->
          Array.to_list tys |> List.filter_map type_name
          |> List.sort_uniq compare
          |> List.concat_map (Hashtbl.find_all type_defs))

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

let references_string ?(encoding = UTF16) src line ch =
  let refs = (analyze src).a_defs in
  let target = (line + 1, byte_column ~encoding src line ch) in
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
    |> List.sort_uniq (fun (a : Wax_utils.Ast.location) b ->
        let c = compare a.loc_start.pos_cnum b.loc_start.pos_cnum in
        if c = 0 then compare a.loc_end.pos_cnum b.loc_end.pos_cnum else c)
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
let occurrence_at ?(encoding = UTF16) src line ch (loc : Wax_utils.Ast.location)
    =
  let target = (line + 1, byte_column ~encoding src line ch) in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  le (pos loc.loc_start) target && le target (pos loc.loc_end)

(* The span of the token to rename (for the editor's prepare step), or [None]
   when the cursor is not on a renameable symbol. *)
let rename_prepare_string ?(encoding = UTF16) src line ch =
  List.find_opt
    (occurrence_at ~encoding src line ch)
    (references_string ~encoding src line ch)

(* The outcome of a rename: the edits to apply, or a message rejecting it —
   [newname] is not a usable identifier, or carrying the rename out would change
   which definition some name resolves to. We decide the latter structurally,
   from the def-use graph ([a_defs], the links go-to-definition is built on) of
   the buffer with the edits applied, not from diagnostics: a parse error
   suppresses the "already bound" message but the graph still resolves what it
   can, so the check keeps working — it only loses coverage, never gains false
   positives — on a buffer that does not fully parse. The [rename_outcome] type
   is shared with the WAT side ({!Editor_common}). *)

(* Splice the rename edits into [src], returning the new buffer and, in the new
   buffer's byte offsets, the span of each replaced identifier. The new name
   sits at the end of every replacement (plain [newname], or [field: newname]
   for a punned struct field), so it is the last [String.length newname] bytes;
   these spans are exactly the renamed symbol's occurrences in the new graph. *)
let apply_rename_edits src newname edits =
  let sorted =
    List.sort
      (fun ((a : Wax_utils.Ast.location), _) ((b : Wax_utils.Ast.location), _)
         -> compare a.loc_start.Lexing.pos_cnum b.loc_start.pos_cnum)
      edits
  in
  let buf = Buffer.create (String.length src + 16) in
  let n = String.length newname in
  let cur, spans =
    List.fold_left
      (fun (cur, spans) ((loc : Wax_utils.Ast.location), repl) ->
        let s = loc.loc_start.pos_cnum and e = loc.loc_end.pos_cnum in
        Buffer.add_substring buf src cur (s - cur);
        Buffer.add_string buf repl;
        let stop = Buffer.length buf in
        (e, (stop - n, stop) :: spans))
      (0, []) sorted
  in
  Buffer.add_substring buf src cur (String.length src - cur);
  (Buffer.contents buf, spans)

(* Does some reference in the renamed graph cross the boundary of the renamed
   symbol — a use outside it now binding to one of its definitions (a foreign
   name captured, or the reverse half of a collision), or a use of it now
   binding to a definition outside it (it escaped to a shadowing name)? Either
   way the rename changed a name's resolution. [renamed_spans] are the symbol's
   occurrences in [src']'s byte offsets. *)
let rename_crosses_binding src' renamed_spans =
  let renamed = Hashtbl.create 16 in
  List.iter (fun k -> Hashtbl.replace renamed k ()) renamed_spans;
  let is_ours (l : Wax_utils.Ast.location) =
    Hashtbl.mem renamed (l.loc_start.Lexing.pos_cnum, l.loc_end.pos_cnum)
  in
  let crosses (r : Wax_lang.Typing.reference) =
    let our_use = is_ours r.use in
    let binds_ours = List.exists is_ours r.definitions in
    let binds_foreign = List.exists (fun d -> not (is_ours d)) r.definitions in
    (our_use && binds_foreign) || ((not our_use) && binds_ours)
  in
  List.exists crosses (analyze src').a_defs

let rename_string ?(encoding = UTF16) src line ch newname =
  let a = analyze src in
  let puns = Hashtbl.create 16 in
  List.iter
    (fun (loc : Wax_utils.Ast.location) ->
      Hashtbl.replace puns (loc.loc_start.pos_cnum, loc.loc_end.pos_cnum) ())
    a.a_puns;
  let is_pun (loc : Wax_utils.Ast.location) =
    Hashtbl.mem puns (loc.loc_start.pos_cnum, loc.loc_end.pos_cnum)
  in
  let edits =
    List.map
      (fun (loc : Wax_utils.Ast.location) ->
        let replacement =
          if is_pun loc then slice src loc ^ ": " ^ newname else newname
        in
        (loc, replacement))
      (references_string ~encoding src line ch)
  in
  if edits = [] then Rename_edits []
  else if not (Wax_lang.Lexer.is_valid_identifier newname) then
    Rename_conflict (Printf.sprintf "%S is not a valid identifier." newname)
  else
    let src', renamed_spans = apply_rename_edits src newname edits in
    let a' = analyze src' in
    (* A name that lexes as an identifier can still be a reserved word in the
       positions it lands in (a keyword like [let] or [if]); such a name breaks
       parsing where a valid one would not, so a syntax error the original did
       not have means the name is unusable here. Only trust this when the
       original parsed cleanly — otherwise we cannot attribute the error. *)
    if a.a_syntax = [] && a'.a_syntax <> [] then
      Rename_conflict
        (Printf.sprintf "%S cannot be used as a name here." newname)
    else if rename_crosses_binding src' renamed_spans then
      Rename_conflict
        (Printf.sprintf
           "Cannot rename to %S: that name is already in use, and the rename \
            would change which definition one or more names refer to."
           newname)
    else Rename_edits edits

(* Cross-language conversion, for the preview commands. [to_wat] compiles Wax to
   Wasm text (mirrors [wax_to_wat] in bin/main.ml: type-check, [To_wasm], print);
   [to_wax] decompiles Wasm text to Wax ([wat_to_wax]: [From_wasm], re-type and
   erase, print). Both trust their input is well formed once it has no errors, so
   they return the source's diagnostics rather than a partial result on failure.
   The converted nodes carry the source locations, so the source comments map
   onto them once their delimiters are retargeted to the other syntax. *)
let to_wat_string src =
  match Wax_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } ->
      Error (String.trim (Wax_utils.Message.to_plain_string message))
  | Ok (ast, ctx) -> (
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      try
        let types, ast = Wax_lang.Typing.f ~warn_unused:false d ast in
        if has_errors d then Error (errors_string d)
        else
          let wasm_ast = Wax_conversion.To_wasm.module_ d types ast in
          let trivia, tail =
            collect_trivia
              ~print:(fun p ~collect ->
                Wax_wasm.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect
                  wasm_ast)
              ~retarget:
                (Wax_utils.Trivia.wax_syntax, Wax_utils.Trivia.wat_syntax)
              ctx
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
let module_completions src ast target bindings =
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
  (* A branch condition as a solver formula, first partially evaluated against
     the [wax.define] bindings: a condition the configuration determines
     collapses to [true_] / [false_] (so a ruled-out branch's definitions become
     unsatisfiable and drop out), while one that still mentions unset variables
     stays symbolic and path-sensitive. With empty bindings [eval] leaves every
     condition residual, so this is exactly the former [of_cond]. *)
  let formula loc c =
    match Wax_wasm.Cond_specialize.eval dctx bindings c with
    | True -> Wax_wasm.Cond_solver.true_
    | False -> Wax_wasm.Cond_solver.false_
    | Residual c -> Wax_wasm.Cond_solver.of_cond env dctx ~location:loc c
  in
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
let is_member_position ?(encoding = UTF16) src line ch =
  let off = line_start_offset src line + byte_column ~encoding src line ch in
  let i = ref (off - 1) in
  while !i >= 0 && is_ident_char src.[!i] do
    decr i
  done;
  !i >= 0 && src.[!i] = '.'

(* The receiver of the member access whose (possibly partial) field span covers
   the cursor in [members], if any. *)
let member_receiver_at ?(encoding = UTF16) src line ch members =
  let target = (line + 1, byte_column ~encoding src line ch) in
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

(* The definition of the type named [name] in the module, for resolving a
   receiver's methods from its declared type. *)
let type_definition ast name =
  let found = ref None in
  Wax_lang.Ast_utils.iter_fields
    (fun field ->
      match field.Wax_lang.Ast.desc with
      | Wax_lang.Ast.Type rectype ->
          Array.iter
            (fun entry ->
              let id, (sub : Wax_lang.Ast.subtype) = entry.Wax_lang.Ast.desc in
              if id.Wax_lang.Ast.desc = name then found := Some sub)
            rectype
      | _ -> ())
    ast;
  !found

(* The rendered parameter and result types of the continuation type named
   [name] — its wrapped function type's signature — plus the results of a
   [switch] on it (the last parameter's own continuation parameters, when it
   has one). [None] when [name] is not a continuation type of the module. *)
let cont_signature ast name =
  let func_sign ct =
    match type_definition ast ct with
    | Some { typ = Cont ft; _ } -> (
        match type_definition ast ft.Wax_lang.Ast.desc with
        | Some { typ = Func sign; _ } -> Some sign
        | _ -> None)
    | _ -> None
  in
  match func_sign name with
  | None -> None
  | Some sign ->
      let render_param p = render_valtype (snd p.Wax_lang.Ast.desc) in
      let params = Array.to_list (Array.map render_param sign.params) in
      let results = Array.to_list (Array.map render_valtype sign.results) in
      let switch_results =
        let n = Array.length sign.params in
        if n = 0 then []
        else
          match snd sign.params.(n - 1).Wax_lang.Ast.desc with
          | Wax_lang.Ast.Ref { typ = Type ct2 | Exact ct2; _ } -> (
              match func_sign ct2.Wax_lang.Ast.desc with
              | Some sign2 ->
                  Array.to_list (Array.map render_param sign2.params)
              | None -> [])
          | _ -> []
      in
      Some (params, results, switch_results)

(* The [T::] members of a declared continuation type — [new]/[bind] — for
   completion and signature help after [ns::]. Empty when [ns] does not name a
   continuation type of the module. *)
let cont_namespace_members ast ns =
  match type_definition ast ns with
  | Some { typ = Cont ft; _ } ->
      let fn member_name member_detail =
        {
          Wax_lang.Typing.member_name;
          member_kind = Wax_lang.Typing.Function;
          member_detail;
        }
      in
      [
        fn "new" (Printf.sprintf "fn(&%s) -> &%s" ft.Wax_lang.Ast.desc ns);
        fn "bind" (Printf.sprintf "fn(bound..., &<k>) -> &%s" ns);
      ]
  | _ -> []

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
let namespace_position ?(encoding = UTF16) src line ch =
  let off = line_start_offset src line + byte_column ~encoding src line ch in
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

let completion_string ?(encoding = UTF16) src line ch defines =
  if is_member_position ~encoding src line ch then
    match member_receiver_at ~encoding src line ch (analyze src).a_members with
    | Some r -> List.map member_completion (Wax_lang.Typing.member_candidates r)
    | None -> (
        (* A bare [.]: the parser drops the field-less access, so nothing is
           recorded. Splice a sentinel field in so [recv.<sentinel>] parses and
           types, then read the receiver's fields at the sentinel (analyzed
           uncached, so the transient buffer does not evict the real one). *)
        let off =
          line_start_offset src line + byte_column ~encoding src line ch
        in
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
    match namespace_position ~encoding src line ch with
    | Some ns -> (
        (* After [ns::]: the intrinsic namespace's free functions, known
           textually, need no parse; a declared continuation type's
           [new]/[bind] members are resolved from the buffer's AST. *)
        match Wax_lang.Typing.namespace_members ns with
        | [] -> (
            let ast_opt, _, _ =
              Wax_parser.parse_recover ~filename:"<buffer>"
                ~sync:Wax_lang.Recover.sync ~insert:Wax_lang.Recover.insert
                ~closers:Wax_lang.Recover.closers src
            in
            match ast_opt with
            | Some ast ->
                List.map member_completion (cont_namespace_members ast ns)
            | None -> [])
        | members -> List.map member_completion members)
    | None -> (
        let target = (line + 1, byte_column ~encoding src line ch) in
        let ast_opt, _syntax_errors, _ctx =
          Wax_parser.parse_recover ~filename:"<buffer>"
            ~sync:Wax_lang.Recover.sync ~insert:Wax_lang.Recover.insert
            ~closers:Wax_lang.Recover.closers src
        in
        let keywords =
          List.map
            (fun k -> { k_name = k; k_kind = "keyword"; k_detail = "" })
            wax_keywords
          @ List.map
              (fun k ->
                {
                  k_name = k ^ ":";
                  k_kind = "keyword";
                  k_detail = "labelled argument";
                })
              [ "align"; "offset"; "lane"; "tag" ]
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
               [#[if]] arm guards; see [module_completions]). The chosen
               [wax.define] set is fed in as an extra assumption, so a definition
               in a branch the configuration rules out drops away and a partial
               set stays path-sensitive. *)
            let module_ =
              module_completions src ast target (define_bindings defines)
            in
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
      let members =
        match Wax_lang.Typing.namespace_members ns.desc with
        | [] -> cont_namespace_members ast ns.desc
        | members -> members
      in
      List.find_map
        (fun (c : Wax_lang.Typing.member_candidate) ->
          if c.member_name = nm.desc then Some c.member_detail else None)
        members
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
          (* an array receiver: its element type selects the array methods; a
             continuation receiver, the resume family and switch *)
          match array_element typed_module n.desc with
          | Some elem -> Some (Wax_lang.Typing.array_method_candidates elem)
          | None -> (
              match cont_signature typed_module n.desc with
              | Some (params, results, switch_results) ->
                  Some
                    (Wax_lang.Typing.cont_method_candidates ~params ~results
                       ~switch_results)
              | None -> Wax_lang.Typing.numeric_receiver_candidates ty))
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
let signature_help_string ?(encoding = UTF16) src line ch =
  match (analyze src).a_typed with
  | None -> None
  | Some ast -> (
      let cursor =
        line_start_offset src line + byte_column ~encoding src line ch
      in
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

(* Selection ranges (expand / shrink selection, Wax only): for the position, the
   chain of enclosing syntactic spans from the innermost node outward, so
   Shift+Alt+Right grows the selection expression -> statement -> block ->
   function -> whole file precisely, rather than by the editor's word / bracket
   heuristic. Built from the recovered parse alone (no typing), so it survives a
   mid-edit buffer. Every field and instruction span covering the cursor is
   collected; since the covering nodes are nested (siblings do not overlap) they
   already form a chain, and deduping by byte span then ordering by width yields
   it innermost-first. The whole buffer is always the outermost step (select
   all). *)
let selection_range_string ?(encoding = UTF16) src line ch =
  let target = (line + 1, byte_column ~encoding src line ch) in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  let contains (loc : Wax_utils.Ast.location) =
    le (pos loc.loc_start) target && le target (pos loc.loc_end)
  in
  let ast_opt, _, _ =
    Wax_parser.parse_recover ~filename:"<buffer>" ~sync:Wax_lang.Recover.sync
      ~insert:Wax_lang.Recover.insert ~closers:Wax_lang.Recover.closers src
  in
  match ast_opt with
  | None -> []
  | Some ast ->
      let spans = ref [ (0, String.length src) ] in
      let add (loc : Wax_utils.Ast.location) =
        if loc.loc_start.pos_cnum >= 0 && contains loc then
          spans := (loc.loc_start.pos_cnum, loc.loc_end.pos_cnum) :: !spans
      in
      Wax_lang.Ast_utils.iter_fields (fun f -> add f.info) ast;
      Wax_lang.Ast_utils.iter_module_instr (fun i -> add i.info) ast;
      (* Dedup identical spans, then order by width. Nested distinct spans have
         distinct widths, so width order is the innermost-first chain. *)
      let pairs =
        List.sort_uniq compare !spans
        |> List.sort (fun (s1, e1) (s2, e2) -> compare (e1 - s1) (e2 - s2))
      in
      let offsets =
        List.concat_map (fun (s, e) -> [ s; e ]) pairs |> List.sort_uniq compare
      in
      let posn = positions ~encoding src offsets in
      List.filter_map
        (fun (s, e) ->
          match (Hashtbl.find_opt posn s, Hashtbl.find_opt posn e) with
          | Some (sl, sc), Some (el, ec) -> Some (sl, sc, el, ec)
          | _ -> None)
        pairs

(* Multi-line block-comment spans as (0-based start line, end line), for comment
   folding. One left-to-right scan tracks string literals (so a [/*] inside a
   string is not a comment) and skips line comments; block comments nest
   ([/* … /* … */ … */]). A comment that stays on one line is not foldable. *)
let block_comment_folds src =
  let n = String.length src in
  let at j = if j < n then src.[j] else '\000' in
  let folds = ref [] and line = ref 0 and i = ref 0 in
  while !i < n do
    let c = src.[!i] in
    if c = '"' then begin
      (* skip a string literal, honoring backslash escapes *)
      incr i;
      let stop = ref false in
      while (not !stop) && !i < n do
        (match src.[!i] with
        | '\\' -> incr i
        | '"' -> stop := true
        | '\n' -> incr line
        | _ -> ());
        incr i
      done
    end
    else if c = '/' && at (!i + 1) = '*' then begin
      let start_line = !line in
      i := !i + 2;
      let depth = ref 1 in
      while !depth > 0 && !i < n do
        if src.[!i] = '/' && at (!i + 1) = '*' then (
          incr depth;
          i := !i + 2)
        else if src.[!i] = '*' && at (!i + 1) = '/' then (
          decr depth;
          i := !i + 2)
        else begin
          if src.[!i] = '\n' then incr line;
          incr i
        end
      done;
      if !line > start_line then folds := (start_line, !line) :: !folds
    end
    else if c = '/' && at (!i + 1) = '/' then
      while !i < n && src.[!i] <> '\n' do
        incr i
      done
    else begin
      if c = '\n' then incr line;
      incr i
    end
  done;
  !folds

(* Folding ranges (Wax only): the block bodies and multi-line block comments the
   editor can collapse. From the recovered parse (so it works mid-edit) it takes
   each field's span (a function, a multi-line [type]/global, …), every braced
   instruction body ([block]/[loop]/[if]/[while]/[try]/[match]/[dispatch] arm),
   and each [#[if]]/[#[else]] branch body; the block-comment scan adds the
   comment folds. Ranges are line-based (VS Code folds whole lines): a range is
   kept only when it spans more than one line, and at most one range per start
   line (the widest) so the fold arrows do not collide. *)
let folding_string src =
  let ast_opt, _, _ =
    Wax_parser.parse_recover ~filename:"<buffer>" ~sync:Wax_lang.Recover.sync
      ~insert:Wax_lang.Recover.insert ~closers:Wax_lang.Recover.closers src
  in
  (* start line -> (end line, kind), keeping the widest fold per start line. *)
  let tbl = Hashtbl.create 64 in
  let add start_line end_line kind =
    if end_line > start_line then
      match Hashtbl.find_opt tbl start_line with
      | Some (e, _) when e >= end_line -> ()
      | _ -> Hashtbl.replace tbl start_line (end_line, kind)
  in
  let add_loc kind (loc : Wax_utils.Ast.location) =
    if loc.loc_start.pos_cnum >= 0 then
      add (loc.loc_start.pos_lnum - 1) (loc.loc_end.pos_lnum - 1) kind
  in
  (match ast_opt with
  | None -> ()
  | Some ast ->
      let open Wax_lang.Ast in
      Wax_lang.Ast_utils.iter_fields
        (fun field ->
          let add_named (name : Wax_lang.Ast.ident) =
            if
              name.info.loc_start.pos_cnum >= 0
              && field.info.loc_start.pos_cnum >= 0
            then
              add
                (name.info.loc_start.pos_lnum - 1)
                (field.info.loc_end.pos_lnum - 1)
                "region"
          in
          match (field.desc : _ modulefield) with
          | Import_group _ -> add_loc "imports" field.info
          | Conditional { then_fields; else_fields; _ } ->
              add_loc "region" then_fields.info;
              Option.iter (fun b -> add_loc "region" b.info) else_fields
          | Func { name; _ } -> add_named name
          | Global { name; _ } -> add_named name
          | Tag { name; _ } -> add_named name
          | Memory { name; _ } -> add_named name
          | Table { name; _ } -> add_named name
          | Elem { name; _ } -> add_named name
          | Data { name = Some name; _ } -> add_named name
          | _ -> add_loc "region" field.info)
        ast;
      Wax_lang.Ast_utils.iter_module_instr
        (fun i ->
          match i.desc with
          | Block { block; _ }
          | Loop { block; _ }
          | While { block; _ }
          | TryTable { block; _ } ->
              add_loc "region" block.info
          | If { if_block; else_block; _ } ->
              add_loc "region" i.info;
              add_loc "region" if_block.info;
              Option.iter (fun b -> add_loc "region" b.info) else_block
          | Try { block; catches; catch_all; _ } ->
              add_loc "region" i.info;
              add_loc "region" block.info;
              List.iter (fun (_, b) -> add_loc "region" b.info) catches;
              Option.iter (fun b -> add_loc "region" b.info) catch_all
          | TryCatch { block; arms; _ } ->
              add_loc "region" i.info;
              add_loc "region" block.info;
              List.iter (fun a -> add_loc "region" a.arm_body.info) arms
          | Match { arms; default; _ } ->
              add_loc "region" i.info;
              List.iter (fun (_, b) -> add_loc "region" b.info) arms;
              add_loc "region" default.info
          | Dispatch { arms; _ } ->
              add_loc "region" i.info;
              List.iter (fun (_, b) -> add_loc "region" b.info) arms
          | If_annotation { then_body; else_body; _ } ->
              add_loc "region" i.info;
              add_loc "region" then_body.info;
              Option.iter (fun b -> add_loc "region" b.info) else_body
          | _ -> ())
        ast);
  List.iter (fun (s, e) -> add s e "comment") (block_comment_folds src);
  Hashtbl.fold (fun s (e, k) acc -> (s, e, k) :: acc) tbl []

(* Classify every identifier occurrence for semantic highlighting. The *uses*
   come from the recorded references ([a_defs]): a use is classified by its
   definition's kind, which the structural walk below records — so a `Get` reads
   as a function / variable / parameter, and a type reference (which resolves to
   a type definition) reads as a type, without re-deriving scope here. The
   *definitions* (function / type / variable / parameter names) come from that
   same walk, and struct fields ([property]) and intrinsic namespace paths from a
   pass over the instructions. *)
let semantic_tokens_string ?(encoding = UTF16) src =
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
         [positions]), then one token per span, sorted; synthesized
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
      let pos = positions ~encoding src offsets in
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

(* The source ranges made unreachable by the conditional-compilation [defines]
   (each a "name" or "name=value" as on the [-D] CLI): for every [#[if]] /
   [If_annotation] whose condition the bindings determine, the body of the branch
   not taken — the [#[else]] when the condition holds, the [#[if]] body when it
   does not; a condition that stays residual (mentions an unset variable) dims
   nothing. A dead branch's own body span is used (not the splice range), so a
   live neighbour's brace is never dimmed; nested dead branches inside it are
   redundant but harmless. Ranges as (startLine, startChar, endLine, endChar),
   0-based, UTF-16; empty when no define is set. *)
let inactive_ranges_string ?(encoding = UTF16) src defines =
  let bindings =
    Wax_wasm.Cond_specialize.of_list
      (List.filter_map
         (fun s ->
           match Wax_wasm.Cond_specialize.parse_define s with
           | Ok b -> Some b
           | Error _ -> None)
         defines)
  in
  if Wax_wasm.Cond_specialize.is_empty bindings then []
  else
    let ast_opt, _, _ =
      Wax_parser.parse_recover ~filename:"<buffer>" ~sync:Wax_lang.Recover.sync
        ~insert:Wax_lang.Recover.insert ~closers:Wax_lang.Recover.closers src
    in
    match ast_opt with
    | None -> []
    | Some ast ->
        let dctx = Wax_utils.Diagnostic.collector ~source:src () in
        let dead = ref [] in
        (* the body not taken for a determined condition: [else] when true, the
           [if] body when false; nothing when the condition stays residual. *)
        let branch cond then_loc else_loc =
          match Wax_wasm.Cond_specialize.eval dctx bindings cond with
          | True -> Option.iter (fun l -> dead := l :: !dead) else_loc
          | False -> dead := then_loc :: !dead
          | Residual _ -> ()
        in
        Wax_lang.Ast_utils.iter_fields
          (fun field ->
            match field.desc with
            | Conditional { cond; then_fields; else_fields } ->
                let else_loc =
                  match else_fields with Some b -> Some b.info | None -> None
                in
                branch cond then_fields.info else_loc
            | _ -> ())
          ast;
        Wax_lang.Ast_utils.iter_module_instr
          (fun i ->
            match i.desc with
            | If_annotation { cond; then_body; else_body } ->
                let else_loc =
                  match else_body with Some b -> Some b.info | None -> None
                in
                branch cond then_body.info else_loc
            | _ -> ())
          ast;
        let dead = !dead in
        let offsets =
          List.concat_map
            (fun (l : Wax_utils.Ast.location) ->
              [ l.loc_start.pos_cnum; l.loc_end.pos_cnum ])
            dead
          |> List.sort_uniq compare
        in
        let pos = positions ~encoding src offsets in
        List.filter_map
          (fun (l : Wax_utils.Ast.location) ->
            match
              ( Hashtbl.find_opt pos l.loc_start.pos_cnum,
                Hashtbl.find_opt pos l.loc_end.pos_cnum )
            with
            | Some (sl, sc), Some (el, ec) when (sl, sc) <> (el, ec) ->
                Some (sl, sc, el, ec)
            | _ -> None)
          dead
