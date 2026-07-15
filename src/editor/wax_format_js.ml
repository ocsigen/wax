(* The Wax toolchain's editor analysis exported to JavaScript, for the VS Code
   extension. It runs in-process under wasm_of_ocaml in both Node (the desktop
   extension host) and the browser (the web extension), and installs
   [globalThis.wax] with methods for both the Wax and the Wasm-text languages.

   All analysis lives in {!Wax_editor} (shared with the native LSP server); this
   module only marshals its results to and from JavaScript. The JS methods and
   the object shapes they return:

   - [format src] / [formatWat src] -> { ok; text; error }: reprint the module
     with its comments preserved, or report why it could not.
   - [check src defines] / [checkWat src] -> array of { severity; message;
     startLine; startChar; endLine; endChar; warning; hint; related }: parse and
     check (type-check for Wax, validate for Wasm text), returning diagnostics.
     [warning] is the [-W] name of a lint warning, or null; [defines] specializes
     to a conditional-compilation configuration.
   - [hover src line ch] -> { type; startLine; startChar; endLine; endChar } or
     null: the type at the (zero-based) position. Wax only.
   - [inlays src] -> array of { line; char; label }: the inferred type on each
     un-annotated [let] binding. Wax only.
   - [definition src line ch] / [typeDefinition src line ch] -> array of
     { startLine; startChar; endLine; endChar }: the definition span(s) for the
     name at the position (or, for [typeDefinition], its type's declaration).
     Wax only.
   - [references src line ch] -> array of { startLine; startChar; endLine;
     endChar }: every occurrence of the symbol at the position. Wax only.
   - [renamePrepare src line ch] -> { startLine; startChar; endLine; endChar } or
     null: the span of the renameable symbol at the position. Wax only.
   - [rename src line ch newname] -> { edits; error }: the edits (each { startLine;
     startChar; endLine; endChar; newText }) to rename the symbol at the position,
     or a non-null [error] message when the rename is rejected. Wax only.
   - [symbols src] / [symbolsWat src] -> nested { name; kind; startLine; …;
     selStartLine; …; children }: the module's definitions, for the outline.
   - [completion src line ch defines] -> array of { name; kind; detail }:
     completion candidates at the position. Wax only.
   - [signatureHelp src line ch] -> { label; parameters; active } or null: the
     enclosing call's signature at the position. Wax only.
   - [selectionRange src line ch] -> array of { startLine; …; endChar }: the
     enclosing spans at the position, innermost first. Wax only.
   - [semanticTokens src] -> array of { line; character; length; kind }. Wax only.
   - [foldingRanges src] -> array of { startLine; endLine; kind }. Wax only.
   - [inactiveRanges src defines] -> array of { startLine; …; endChar }: the
     spans a conditional-compilation configuration makes unreachable. Wax only.
   - [toWat src] / [toWax src] -> { ok; text; error }: convert between the
     languages, for the side-by-side preview commands. *)

open Js_of_ocaml
open Editor_common
open Wax_editor

let js_related src (message, (location : Wax_utils.Ast.location)) =
  let start_line, start_char = utf16_position src location.loc_start in
  let end_line, end_char = utf16_position src location.loc_end in
  object%js
    val message = Js.string (String.trim message)
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
  end

let js_diagnostic src d =
  let start_line, start_char = utf16_position src d.location.loc_start in
  let end_line, end_char = utf16_position src d.location.loc_end in
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

    val unnecessary = Js.bool d.unnecessary

    val hint =
      match d.hint with
      | Some h -> Js.some (Js.string (String.trim h))
      | None -> Js.null

    val related = Js.array (Array.of_list (List.map (js_related src) d.related))
  end

let js_hover src h =
  let start_line, start_char = utf16_position src h.h_range.loc_start in
  let end_line, end_char = utf16_position src h.h_range.loc_end in
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
  let line, char = utf16_position src n.n_pos in
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

(* [check] with the editor's [wax.define] configuration threaded in: the
   diagnostics are specialized to that set. A missing / empty array leaves the
   ordinary path-sensitive check. *)
let check_result_defines src defines =
  let s = Js.to_string src in
  let defines =
    try Js.to_array defines |> Array.to_list |> List.map Js.to_string
    with _ -> []
  in
  let diagnostics = try check_string_with_defines s defines with _ -> [] in
  Js.array (Array.of_list (List.map (js_diagnostic s) diagnostics))

(* [null] when there is no typed node under the cursor (or anything went wrong):
   the provider then shows no hover rather than crashing the host. *)
let hover_result hover src line ch =
  let s = Js.to_string src in
  match try hover s line ch with _ -> None with
  | None -> Js.null
  | Some h -> Js.some (js_hover s h)

let inlays_result src =
  let s = Js.to_string src in
  let hints = try inlays_string s with _ -> [] in
  Js.array (Array.of_list (List.map (js_inlay s) hints))

(* Each definition as a plain range object; empty array when nothing resolves. *)
let js_range src (loc : Wax_utils.Ast.location) =
  let start_line, start_char = utf16_position src loc.loc_start in
  let end_line, end_char = utf16_position src loc.loc_end in
  object%js
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
  end

let definition_result definition src line ch =
  let s = Js.to_string src in
  let defs = try definition s line ch with _ -> [] in
  Js.array (Array.of_list (List.map (js_range s) defs))

let type_definition_result type_definition src line ch =
  let s = Js.to_string src in
  let defs = try type_definition s line ch with _ -> [] in
  Js.array (Array.of_list (List.map (js_range s) defs))

let references_result references src line ch =
  let s = Js.to_string src in
  let occurrences = try references s line ch with _ -> [] in
  Js.array (Array.of_list (List.map (js_range s) occurrences))

(* [null] when the cursor is not on a renameable symbol; the provider then
   reports that rename is not available here. *)
let rename_prepare_result rename_prepare src line ch =
  let s = Js.to_string src in
  match try rename_prepare s line ch with _ -> None with
  | None -> Js.null
  | Some loc -> Js.some (js_range s loc)

let js_edit src (loc, newText) =
  let start_line, start_char = utf16_position src loc.Wax_utils.Ast.loc_start in
  let end_line, end_char = utf16_position src loc.loc_end in
  object%js
    val startLine = start_line
    val startChar = start_char
    val endLine = end_line
    val endChar = end_char
    val newText = Js.string newText
  end

(* [{ edits; error }]: the rename edits, or an [error] message when the rename
   is rejected (an unusable name, or a change that would clash with an existing
   name); the provider surfaces the message instead of editing. *)
let rename_object s edits error =
  object%js
    val edits = Js.array (Array.of_list (List.map (js_edit s) edits))

    val error =
      match error with Some e -> Js.some (Js.string e) | None -> Js.null
  end

let rename_result src line ch newname =
  let s = Js.to_string src in
  let n = Js.to_string newname in
  match try rename_string s line ch n with _ -> Rename_edits [] with
  | Rename_edits edits -> rename_object s edits None
  | Rename_conflict message -> rename_object s [] (Some message)

(* WAT rename cannot clash (it rewrites [$id] tokens only), so its result always
   has a null [error]. *)
let rename_wat_result src line ch newname =
  let s = Js.to_string src in
  let n = Js.to_string newname in
  let edits = try Wat_editor.rename_string s line ch n with _ -> [] in
  rename_object s edits None

let rec js_symbol src s =
  let start_line, start_char = utf16_position src s.s_range.loc_start in
  let end_line, end_char = utf16_position src s.s_range.loc_end in
  let sel_start_line, sel_start_char =
    utf16_position src s.s_selection.loc_start
  in
  let sel_end_line, sel_end_char = utf16_position src s.s_selection.loc_end in
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

let js_completion c =
  object%js
    val name = Js.string c.k_name
    val kind = Js.string c.k_kind
    val detail = Js.string c.k_detail
  end

let completion_result src line ch defines =
  let defines =
    try Js.to_array defines |> Array.to_list |> List.map Js.to_string
    with _ -> []
  in
  let items =
    try completion_string (Js.to_string src) line ch defines with _ -> []
  in
  Js.array (Array.of_list (List.map js_completion items))

let signature_result signature_help src line ch =
  match try signature_help (Js.to_string src) line ch with _ -> None with
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

let inactive_ranges_result src defines =
  let defines = Js.to_array defines |> Array.to_list |> List.map Js.to_string in
  let ranges =
    try inactive_ranges_string (Js.to_string src) defines with _ -> []
  in
  Js.array
    (Array.of_list
       (List.map
          (fun (sl, sc, el, ec) ->
            object%js
              val startLine = sl
              val startChar = sc
              val endLine = el
              val endChar = ec
            end)
          ranges))

let selection_range_result selection_range src line ch =
  let ranges = try selection_range (Js.to_string src) line ch with _ -> [] in
  Js.array
    (Array.of_list
       (List.map
          (fun (sl, sc, el, ec) ->
            object%js
              val startLine = sl
              val startChar = sc
              val endLine = el
              val endChar = ec
            end)
          ranges))

let folding_result folding src =
  let folds = try folding (Js.to_string src) with _ -> [] in
  Js.array
    (Array.of_list
       (List.map
          (fun (s, e, kind) ->
            object%js
              val startLine = s
              val endLine = e
              val kind = Js.string kind
            end)
          folds))

let semantic_result semantic_tokens src =
  let toks = try semantic_tokens (Js.to_string src) with _ -> [] in
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
      method check src defines = check_result_defines src defines
      method hover src line ch = hover_result hover_string src line ch
      method inlays src = inlays_result src

      method definition src line ch =
        definition_result definition_string src line ch

      method typeDefinition src line ch =
        type_definition_result type_definition_string src line ch

      method references src line ch =
        references_result references_string src line ch

      method renamePrepare src line ch =
        rename_prepare_result rename_prepare_string src line ch

      method rename src line ch newname = rename_result src line ch newname
      method symbols src = symbols_result symbols_string src

      method completion src line ch defines =
        completion_result src line ch defines

      method signatureHelp src line ch =
        signature_result signature_help_string src line ch

      method selectionRange src line ch =
        selection_range_result selection_range_string src line ch

      method semanticTokens src = semantic_result semantic_tokens_string src
      method foldingRanges src = folding_result folding_string src
      method inactiveRanges src defines = inactive_ranges_result src defines
      method formatWat src = format_result Wat_editor.format_string src
      method checkWat src = check_result Wat_editor.check_string src
      method symbolsWat src = symbols_result Wat_editor.symbols_string src
      method toWat src = format_result to_wat_string src
      method toWax src = format_result Wat_editor.to_wax_string src

      method hoverWat src line ch =
        hover_result Wat_editor.hover_string src line ch

      method definitionWat src line ch =
        definition_result Wat_editor.definition_string src line ch

      method referencesWat src line ch =
        references_result Wat_editor.references_string src line ch

      method renamePrepareWat src line ch =
        rename_prepare_result Wat_editor.rename_prepare_string src line ch

      method renameWat src line ch newname =
        rename_wat_result src line ch newname

      method selectionRangeWat src line ch =
        selection_range_result Wat_editor.selection_range_string src line ch

      method foldingRangesWat src = folding_result Wat_editor.folding_string src

      method semanticTokensWat src =
        semantic_result Wat_editor.semantic_tokens_string src

      method signatureHelpWat src line ch =
        signature_result Wat_editor.signature_help_string src line ch

      method typeDefinitionWat src line ch =
        type_definition_result Wat_editor.type_definition_string src line ch
    end
