(* The Wasm-text (WAT) editor analysis: formatting, checking, and the
   language-server features for [.wat] buffers, as pure functions over source
   text. The Wax counterpart is {!Wax_editor}; the shared value types and helpers
   are in {!Editor_common}. Every feature is a [*_string] function returning a
   plain OCaml value; the JS marshalling and the LSP protocol mapping live in the
   consumers, not here. *)

open Editor_common

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

let format_string src =
  match Wat_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } ->
      Error (String.trim (Wax_utils.Message.to_plain_string message))
  | Ok (ast, ctx) ->
      let trivia, tail =
        collect_trivia ctx ~print:(fun p ~collect ->
            Wax_wasm.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect ast)
      in
      let buf = Buffer.create (String.length src) in
      let fmt = Format.formatter_of_buffer buf in
      let print_wat f m =
        Wax_utils.Printer.run f (fun p ->
            Wax_wasm.Output.module_ ~color:Wax_utils.Colors.Never p ~trivia
              ~tail m)
      in
      Format.fprintf fmt "%a@." print_wat ast;
      Ok (Buffer.contents buf)

(* Everything a WAT buffer's language features read, computed by one recovered
   parse followed by one validation pass (with the type sink on) and one
   name-resolution pass. A single pass serves hover, navigation, diagnostics and
   the structural features alike, so an unchanged buffer is analysed once no
   matter which feature fires. *)
type analysis = {
  a_ast : Wax_utils.Ast.location Wax_wasm.Ast.Text.module_ option;
  a_syntax : diag list;  (** Syntax errors from the recovered parse. *)
  a_diagnostics : diag list;  (** Validation / lint diagnostics. *)
  a_types :
    (Wax_utils.Ast.location * int * Wax_wasm.Validation.recorded_type) list;
      (** The validator's recorded [(span, configuration, type)] entries. *)
  a_bindings : Wax_wasm.Resolve.binding list;
      (** The name-resolution use -> definition table. *)
}

(* Parse with the WAT recovery config (so a broken buffer still yields a
   best-effort AST), then validate it in recovery mode — [set_recovery] makes
   [Validation] suppress the warnings and stack-shape cascades a dropped or
   auto-closed construct triggers, while real errors in the intact regions still
   show — harvesting the type sink as we go, and resolve names. Validation may
   abort mid-pass; whatever it recorded and collected up to that point still
   stands, so read the sink and the collector regardless (as the Wax side does). *)
let analyze_uncached src =
  let ast_opt, syntax_errors, _ =
    Wat_parser.parse_recover ~filename:"<buffer>" ~sync:Wax_wasm.Recover.sync
      ~insert:Wax_wasm.Recover.insert ~closers:Wax_wasm.Recover.closers
      ~barrier:Wax_wasm.Recover.barrier src
  in
  let a_syntax = List.map syntax_error_diag syntax_errors in
  match ast_opt with
  | None ->
      {
        a_ast = None;
        a_syntax;
        a_diagnostics = [];
        a_types = [];
        a_bindings = [];
      }
  | Some ast ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      Wax_utils.Diagnostic.set_recovery d (syntax_errors <> []);
      let types = ref [] in
      (try Wax_wasm.Validation.f ~warn_unused:true ~record_types:types d ast
       with Wax_utils.Diagnostic.Aborted -> ());
      {
        a_ast = Some ast;
        a_syntax;
        a_diagnostics = collected_diags d;
        a_types = !types;
        a_bindings = Wax_wasm.Resolve.f ast;
      }

(* Cache the analysis, keyed by the exact source, so a feature invoked
   repeatedly on an unchanged buffer (hover, once per mouse-hover) does not
   re-parse and re-validate each time, and all features share the one pass. A
   handful of recent buffers are kept; an edit changes the source and so is a
   fresh entry, evicting the oldest. Mirrors {!Wax_editor}'s [analyze]. *)
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

(* The validator's recorded [(span, configuration, type)] entries — the raw
   material for WAT hover, type-definition and signature help. *)
let wat_type_map src = (analyze src).a_types

(* As [hover_string], but for WAT: the type the innermost instruction under the
   cursor leaves on the stack, from the validator's recorded types. A
   multi-result instruction contributes one entry per result within a
   configuration; those are joined in stack order into a tuple on one line. A
   span whose type varies across conditional-compilation configurations
   contributes an entry per configuration; those are shown one alternative per
   line. An instruction that produces no value renders to nothing, so its span
   yields no hover rather than the enclosing instruction's type. *)
let hover_string ?(encoding = UTF16) src line ch =
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
  let entries = wat_type_map src in
  (* The innermost span (smallest width) covering the cursor. *)
  let best =
    List.fold_left
      (fun best (loc, _cfg, _rt) ->
        if contains loc then
          match best with
          | Some bloc when span bloc <= span loc -> best
          | _ -> Some loc
        else best)
      None entries
  in
  match best with
  | None -> None
  | Some loc -> (
      (* Group the entries at that span by configuration, in push order:
         within a configuration the results form one tuple line; distinct
         configurations become distinct lines. Identical lines (a config-neutral
         span recorded once per configuration) collapse. *)
      let lines =
        List.rev entries
        |> List.fold_left
             (fun acc (l, cfg, rt) ->
               if l <> loc then acc
               else
                 match Wax_wasm.Validation.render_recorded_type rt with
                 | None -> acc
                 | Some t -> (
                     match List.assoc_opt cfg acc with
                     | Some _ ->
                         List.map
                           (fun (c, ts) ->
                             if c = cfg then (c, ts ^ " " ^ t) else (c, ts))
                           acc
                     | None -> acc @ [ (cfg, t) ]))
             []
        |> List.map snd
      in
      let seen = Hashtbl.create 8 in
      let lines =
        List.filter
          (fun t ->
            if Hashtbl.mem seen t then false
            else (
              Hashtbl.replace seen t ();
              true))
          lines
      in
      match lines with
      | [] -> None
      | _ -> Some { h_type = String.concat "\n" lines; h_range = loc })

(* As [type_definition_string], but for WAT: from the value or type identifier
   under the cursor, the definition of its type — a local/parameter/result of a
   named reference type jumps to that type's definition, and a type reference
   jumps to the type. The validator records the target type's definition span at
   each such value/reference span. *)
let type_definition_string ?(encoding = UTF16) src line ch =
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
  let best =
    List.fold_left
      (fun best (loc, _cfg, rt) ->
        match Wax_wasm.Validation.type_def_location rt with
        | Some def when contains loc -> (
            match best with
            | Some (bloc, _) when span bloc <= span loc -> best
            | _ -> Some (loc, def))
        | _ -> best)
      None (wat_type_map src)
  in
  match best with Some (_, def) -> [ def ] | None -> []

(* The WAT name-resolution bindings for the buffer, from the recovered parse (so
   navigation works mid-edit). *)
let wat_bindings src = (analyze src).a_bindings

(* The binding whose definition or one of whose uses covers the cursor (smallest
   span winning), together with that covering occurrence's span. *)
let wat_binding_at ~encoding src line ch =
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
  List.fold_left
    (fun best (b : Wax_wasm.Resolve.binding) ->
      let occ = b.defs @ b.uses in
      List.fold_left
        (fun best loc ->
          if contains loc then
            match best with
            | Some (_, bloc) when span bloc <= span loc -> best
            | _ -> Some (b, loc)
          else best)
        best occ)
    None (wat_bindings src)

(* All occurrences of a binding (its definition, if named, then its uses). *)
let wat_occurrences (b : Wax_wasm.Resolve.binding) = b.defs @ b.uses

(* As [definition_string], but for WAT: the definition span of the symbol under
   the cursor (empty for an anonymous / numeric-only definition). *)
let definition_string ?(encoding = UTF16) src line ch =
  match wat_binding_at ~encoding src line ch with
  | Some (b, _) -> b.Wax_wasm.Resolve.defs
  | None -> []

(* As [references_string], but for WAT: every occurrence of the symbol under the
   cursor (definition and uses), for find-references and document-highlight. *)
let references_string ?(encoding = UTF16) src line ch =
  match wat_binding_at ~encoding src line ch with
  | Some (b, _) -> wat_occurrences b
  | None -> []

(* Inlay hints for WAT: after a numeric index that resolves to a named
   definition, show that definition's name, so [(local.get 0)] reads as
   [(local.get 0 $x)] and [(call 2)] as [(call 2 $foo)]. Only numeric uses of a
   named definition qualify — a symbolic [$id] use already shows the name, and an
   anonymous definition has none to show — so a fully-named module produces no
   hints (nothing implicit) and a fully-numeric one none either (nothing to
   name); the hints appear exactly where a numeric reference points at a name.
   This is the WAT counterpart of the Wax inferred-type inlay: WAT is explicitly
   typed, so what is implicit is the name behind an index, not a type. *)
let inlays_string src =
  List.concat_map
    (fun (b : Wax_wasm.Resolve.binding) ->
      match b.defs with
      | [] -> []
      | def :: _ ->
          let name = slice src def in
          List.filter_map
            (fun (loc : Wax_utils.Ast.location) ->
              let text = slice src loc in
              if String.length text > 0 && text.[0] <> '$' then
                Some { n_pos = loc.loc_end; n_label = " " ^ name }
              else None)
            b.uses)
    (wat_bindings src)

(* As [rename_prepare_string], but for WAT: the span at the cursor, if it sits on
   a symbolic ([$id]) occurrence of a named definition. A numeric index use or an
   anonymous definition is not renameable. *)
let rename_prepare_string ?(encoding = UTF16) src line ch =
  match wat_binding_at ~encoding src line ch with
  | Some (b, occ) when b.Wax_wasm.Resolve.defs <> [] ->
      let text = slice src occ in
      if String.length text > 0 && text.[0] = '$' then Some occ else None
  | _ -> None

(* Splice the rename edits into [src], returning the new buffer. *)
let apply_wat_rename_edits src edits =
  let sorted =
    List.sort
      (fun ((a : Wax_utils.Ast.location), _) ((b : Wax_utils.Ast.location), _)
         -> compare a.loc_start.Lexing.pos_cnum b.loc_start.pos_cnum)
      edits
  in
  let buf = Buffer.create (String.length src + 16) in
  let cur =
    List.fold_left
      (fun cur ((loc : Wax_utils.Ast.location), repl) ->
        let s = loc.loc_start.pos_cnum and e = loc.loc_end.pos_cnum in
        Buffer.add_substring buf src cur (s - cur);
        Buffer.add_string buf repl;
        e)
      0 sorted
  in
  Buffer.add_substring buf src cur (String.length src - cur);
  Buffer.contents buf

(* Map a byte offset in [src] to its offset in the buffer with [edits] applied:
   every edit that starts strictly before it shifts it by that edit's length
   delta. Used to follow a definition token across the rewrite. *)
let map_wat_offset edits off =
  List.fold_left
    (fun acc ((l : Wax_utils.Ast.location), repl) ->
      if l.loc_start.Lexing.pos_cnum < off then
        acc + String.length repl - (l.loc_end.pos_cnum - l.loc_start.pos_cnum)
      else acc)
    off edits

(* Would carrying out [edits] on the binding [b] (whose definition's first token
   is at [def_start] in [src]) change which definition some name resolves to?
   WAT index spaces are flat, so a clash shows up structurally: after the
   rewrite, re-resolve and find the binding that still owns the renamed
   definition; if its occurrence count differs from [b]'s, the new name either
   merged [b] with a same-space namesake (a collision) or captured / lost a
   reference (a shadowed label), in every case rebinding a name. A clean rename
   relabels each token one-for-one, leaving every binding's occurrence count
   untouched. Numeric-index uses are counted on both sides, so they never trip
   the check. *)
let wat_rename_clashes src edits (b : Wax_wasm.Resolve.binding) def_start =
  let before = List.length b.defs + List.length b.uses in
  let src' = apply_wat_rename_edits src edits in
  let new_def_start = map_wat_offset edits def_start in
  match
    List.find_opt
      (fun (b' : Wax_wasm.Resolve.binding) ->
        List.exists
          (fun (d : Wax_utils.Ast.location) ->
            d.loc_start.Lexing.pos_cnum = new_def_start)
          b'.defs)
      (wat_bindings src')
  with
  | None -> true (* the definition token vanished — the name broke the parse *)
  | Some b' -> List.length b'.defs + List.length b'.uses <> before

(* As [rename_string], but for WAT. Only symbolic ([$id]) occurrences are
   rewritten — a numeric index use of the same definition is left untouched — and
   the replacement keeps the leading [$]. A rename that would collide with an
   existing name in the same (flat) index space, or otherwise rebind a name, is
   rejected with a [Rename_conflict]. *)
let rename_string ?(encoding = UTF16) src line ch newname =
  match wat_binding_at ~encoding src line ch with
  | Some (b, _) when b.Wax_wasm.Resolve.defs <> [] ->
      let repl =
        if String.length newname > 0 && newname.[0] = '$' then newname
        else "$" ^ newname
      in
      let edits =
        List.filter_map
          (fun loc ->
            let text = slice src loc in
            if String.length text > 0 && text.[0] = '$' then Some (loc, repl)
            else None)
          (wat_occurrences b)
      in
      if edits = [] then Rename_edits []
      else
        let def_start =
          (List.hd b.Wax_wasm.Resolve.defs).Wax_utils.Ast.loc_start.pos_cnum
        in
        if wat_rename_clashes src edits b def_start then
          Rename_conflict
            (Printf.sprintf
               "Cannot rename to %S: that name is already in use, and the \
                rename would change which definition one or more names refer \
                to."
               repl)
        else Rename_edits edits
  | _ -> Rename_edits []

(* The completion kind word for an index space, matching the vocabulary the LSP
   / JS consumers map to icons. *)
let completion_kind (k : Wax_wasm.Resolve.kind) =
  match k with
  | Func -> "function"
  | Global -> "variable"
  | Type -> "type"
  | Param -> "parameter"
  | Local -> "variable"
  | Field -> "field"
  | Tag -> "event"
  | Label | Memory | Table | Elem | Data -> "text"

(* As [completion_string], but for WAT. WAT operands are all indices into flat
   spaces, and the kind of index a position wants is fixed by the enclosing
   instruction — so where the user is typing an index (or has just opened one,
   which the recovering parse repairs by inserting a placeholder [0]), we know
   whether functions, globals, locals, types, labels, … belong there. Resolve
   notes each index use-site with the names in scope for the space it expects;
   completion finds the use-site at the cursor and offers those names (with their
   leading [$]), letting the client filter by the prefix already typed. Anywhere
   else (a mnemonic, a keyword) there is no index use-site, so nothing is
   offered. *)
let completion_string ?(encoding = UTF16) src line ch (_defines : string list) =
  match (analyze src).a_ast with
  | None -> []
  | Some ast -> (
      let target = (line + 1, byte_column ~encoding src line ch) in
      let pos (p : Lexing.position) =
        (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
      in
      let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
      let contains (loc : Wax_utils.Ast.location) =
        le (pos loc.loc_start) target && le target (pos loc.loc_end)
      in
      let width (loc : Wax_utils.Ast.location) =
        loc.loc_end.Lexing.pos_cnum - loc.loc_start.pos_cnum
      in
      let expected = ref [] in
      ignore (Wax_wasm.Resolve.f ~expected ast);
      (* The narrowest index use-site covering the cursor (a zero-width inserted
         placeholder wins over any wider token that might abut it). *)
      let best =
        List.fold_left
          (fun best (e : Wax_wasm.Resolve.expected) ->
            if contains e.e_loc then
              match best with
              | Some (b : Wax_wasm.Resolve.expected)
                when width b.e_loc <= width e.e_loc ->
                  best
              | _ -> Some e
            else best)
          None !expected
      in
      match best with
      | None -> []
      | Some e ->
          let seen = Hashtbl.create 32 in
          List.filter_map
            (fun (name, kind, hover) ->
              let k_name = "$" ^ name in
              let key = (k_name, kind) in
              if Hashtbl.mem seen key then None
              else (
                Hashtbl.add seen key ();
                Some
                  {
                    k_name;
                    k_kind = completion_kind kind;
                    k_detail = Option.value hover ~default:"";
                  }))
            (e.e_candidates ()))

(* As [check_string] but for WAT: the recovered parse's syntax errors together
   with the validation / lint diagnostics, both from the shared analysis. *)
let check_string src =
  let a = analyze src in
  a.a_syntax @ a.a_diagnostics

(* Quick fixes for a code-action request over the range, mirroring
   [Wax_editor.code_actions]: every diagnostic carrying a machine-applicable
   [edit] whose edit span (or the diagnostic span it anchors to) meets the
   request range. WAT has no conditional-compilation defines, so unlike the Wax
   side there is nothing to specialize. The shared recovery driver derives the
   syntax-error fixes ([Wax_wasm.Recover.insert]); a validation lint's [edit]
   (e.g. a redundant cast) rides along the same way. *)
let code_actions ?(encoding = UTF16) src (start_line, start_char)
    (end_line, end_char) =
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  let meets (loc : Wax_utils.Ast.location) =
    let s = position ~encoding src loc.loc_start in
    let e = position ~encoding src loc.loc_end in
    le (start_line, start_char) e && le s (end_line, end_char)
  in
  check_string src
  |> List.filter_map (fun (d : diag) ->
      match d.edit with
      | None -> None
      | Some edit ->
          if meets edit.edit_location || meets d.location then
            Some (d.message, edit)
          else None)

let to_wax_string src =
  match Wat_parser.parse_diagnostics ~filename:"<buffer>" src with
  | Error { message; _ } ->
      Error (String.trim (Wax_utils.Message.to_plain_string message))
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
            collect_trivia
              ~print:(fun p ~collect ->
                Wax_lang.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect
                  wax_ast)
              ~retarget:
                (Wax_utils.Trivia.wat_syntax, Wax_utils.Trivia.wax_syntax)
              ctx
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
  | Feature_annotation _ -> []
  | Module_if_annotation _ -> []

(* As [symbols_string], but for WAT, and with the WAT recovery config (parens as
   sync points, the placeholder operand, closers, and the field-keyword barrier),
   so a broken buffer still outlines the fields around the error instead of
   collapsing to an empty outline. Syntax errors are ignored here; the intact
   fields of the best-effort AST are outlined. *)
let symbols_string src =
  match (analyze src).a_ast with
  | None -> []
  | Some (_name, fields) -> List.concat_map wat_field_symbols fields

(* Iterate [f] over every WAT module field, descending into the branches of an
   [(@if …)] conditional annotation (whose bodies hold nested fields), so a field
   guarded by a condition is walked like any other. *)
let rec wat_iter_fields f fields =
  let open Wax_wasm.Ast in
  List.iter
    (fun (field :
           ( Wax_utils.Ast.location Wax_wasm.Ast.Text.modulefield,
             Wax_utils.Ast.location )
           annotated) ->
      f field;
      match field.desc with
      | Text.Module_if_annotation { then_fields; else_fields; _ } ->
          wat_iter_fields f then_fields.desc;
          Option.iter (fun b -> wat_iter_fields f b.desc) else_fields
      | _ -> ())
    fields

(* Apply [f] to every instruction (recursively) in a WAT field's code — a
   function body, or a global / elem / data / table initializer expression. *)
let wat_field_iter_instr f
    (field :
      ( Wax_utils.Ast.location Wax_wasm.Ast.Text.modulefield,
        Wax_utils.Ast.location )
      Wax_wasm.Ast.annotated) =
  let open Wax_wasm.Ast.Text in
  let expr e = List.iter (Wax_wasm.Ast_utils.iter_instr f) e in
  match field.desc with
  | Func { instrs; _ } -> expr instrs
  | Global { init; _ } -> expr init
  | Elem { init; _ } -> List.iter expr init
  | Data { mode = Active (_, e); _ } -> expr e
  | Table { init = Init_expr e; _ } -> expr e
  | Table { init = Init_segment es; _ } -> List.iter expr es
  | _ -> ()

(* As [signature_help_string], but for WAT: inside a folded direct call
   [(call $f a b …)], the callee's signature with the operand under the cursor as
   the active parameter. The signature is the validator's recorded type at the
   callee identifier; the active parameter is how many operands end before the
   cursor. Only folded direct calls ([call]/[return_call]) qualify — an unfolded
   call takes its arguments off the stack, so there is no argument position to
   track. *)
let signature_help_string ?(encoding = UTF16) src line ch =
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
  let same_span (a : Wax_utils.Ast.location) (b : Wax_utils.Ast.location) =
    a.loc_start.pos_cnum = b.loc_start.pos_cnum
    && a.loc_end.pos_cnum = b.loc_end.pos_cnum
  in
  let a = analyze src in
  match a.a_ast with
  | None -> None
  | Some (_name, fields) -> (
      (* The innermost folded direct call whose span covers the cursor. *)
      let best = ref None in
      let consider i =
        let open Wax_wasm.Ast in
        let open Text in
        match i.desc with
        | Folded ({ desc = Call idx | ReturnCall idx; _ }, args)
          when contains i.info -> (
            match !best with
            | Some (bloc, _, _) when span bloc <= span i.info -> ()
            | _ -> best := Some (i.info, idx, args))
        | _ -> ()
      in
      wat_iter_fields (fun f -> wat_field_iter_instr consider f) fields;
      match !best with
      | None -> None
      | Some (_, idx, args) -> (
          let signature =
            List.find_map
              (fun (loc, _cfg, rt) ->
                if same_span loc idx.Wax_wasm.Ast.info then
                  Wax_wasm.Validation.signature_labels rt
                else None)
              a.a_types
          in
          match signature with
          | None -> None
          | Some (params, results) ->
              (* The active parameter: how many operands end before the cursor,
                 clamped to the parameter count. *)
              let active =
                let open Wax_wasm.Ast in
                List.fold_left
                  (fun acc a ->
                    if le (pos a.info.loc_end) target then acc + 1 else acc)
                  0 args
              in
              let nparams = List.length params in
              let active =
                if nparams = 0 then 0 else min active (nparams - 1)
              in
              let buf = Buffer.create 64 in
              Buffer.add_string buf "func (";
              let ranges =
                List.mapi
                  (fun i p ->
                    if i > 0 then Buffer.add_string buf ", ";
                    let s = Buffer.length buf in
                    Buffer.add_string buf p;
                    (s, Buffer.length buf))
                  params
              in
              Buffer.add_char buf ')';
              (match results with
              | [] -> ()
              | _ ->
                  Buffer.add_string buf " -> ";
                  Buffer.add_string buf (String.concat ", " results));
              Some (Buffer.contents buf, ranges, active)))

(* As [selection_range_string], but for WAT: the chain of enclosing field and
   instruction spans covering the cursor, innermost first, from the recovered
   parse (so it survives a mid-edit buffer). *)
let selection_range_string ?(encoding = UTF16) src line ch =
  let target = (line + 1, byte_column ~encoding src line ch) in
  let pos (p : Lexing.position) =
    (p.Lexing.pos_lnum, p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  let le (l1, c1) (l2, c2) = l1 < l2 || (l1 = l2 && c1 <= c2) in
  let contains (loc : Wax_utils.Ast.location) =
    le (pos loc.loc_start) target && le target (pos loc.loc_end)
  in
  match (analyze src).a_ast with
  | None -> []
  | Some (_name, fields) ->
      let spans = ref [ (0, String.length src) ] in
      let add (loc : Wax_utils.Ast.location) =
        if loc.loc_start.pos_cnum >= 0 && contains loc then
          spans := (loc.loc_start.pos_cnum, loc.loc_end.pos_cnum) :: !spans
      in
      wat_iter_fields
        (fun f ->
          add f.info;
          wat_field_iter_instr (fun i -> add i.info) f)
        fields;
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

(* Multi-line block-comment spans for WAT, for comment folding. As
   [block_comment_folds] but for Wasm-text comment syntax: line comments are
   [;;] and block comments are [(; … ;)] (which nest). *)
let wat_block_comment_folds src =
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
    else if c = '(' && at (!i + 1) = ';' then begin
      let start_line = !line in
      i := !i + 2;
      let depth = ref 1 in
      while !depth > 0 && !i < n do
        if src.[!i] = '(' && at (!i + 1) = ';' then (
          incr depth;
          i := !i + 2)
        else if src.[!i] = ';' && at (!i + 1) = ')' then (
          decr depth;
          i := !i + 2)
        else begin
          if src.[!i] = '\n' then incr line;
          incr i
        end
      done;
      if !line > start_line then folds := (start_line, !line) :: !folds
    end
    else if c = ';' && at (!i + 1) = ';' then
      while !i < n && src.[!i] <> '\n' do
        incr i
      done
    else begin
      if c = '\n' then incr line;
      incr i
    end
  done;
  !folds

(* As [folding_string], but for WAT: each field span, every block-like
   instruction body ([block]/[loop]/[if]/[try]/[try_table]), the branches of an
   [(@if …)] annotation, and the multi-line [(; ;)] comments. From the recovered
   parse so it works mid-edit. *)
let folding_string src =
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
  (match (analyze src).a_ast with
  | None -> ()
  | Some (_name, fields) ->
      let open Wax_wasm.Ast in
      let open Text in
      wat_iter_fields
        (fun field ->
          (match field.desc with
          | Import_group1 _ | Import_group2 _ -> add_loc "imports" field.info
          | Module_if_annotation { then_fields; else_fields; _ } ->
              add_loc "region" then_fields.info;
              Option.iter (fun b -> add_loc "region" b.info) else_fields
          | _ -> add_loc "region" field.info);
          wat_field_iter_instr
            (fun i ->
              (* Fold the whole control instruction (from [(block]/[(if]/… to its
                 closing paren); a WAT block body's own span excludes the outer
                 parens, so folding the instruction is what collapses the
                 construct as the editor expects. *)
              match i.desc with
              | Block _ | Loop _ | If _ | TryTable _ | Try _ ->
                  add_loc "region" i.info
              | _ -> ())
            field)
        fields);
  List.iter (fun (s, e) -> add s e "comment") (wat_block_comment_folds src);
  Hashtbl.fold (fun s (e, k) acc -> (s, e, k) :: acc) tbl []

(* As [inactive_ranges_string], but for WAT: the spans a conditional-compilation
   configuration ([defines], mirroring [-D]) makes unreachable — the branch of an
   [(@if …)] the [defines] rule out — so the editor can dim them. Applies to both
   the field-level [(@then …)/(@else …)] of a [Module_if_annotation] and the
   instruction-level one, evaluating each condition with the shared
   [Cond_specialize]; a condition left residual by a partial [defines] set dims
   nothing. Empty when no defines are set (nothing to specialize against). *)
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
    match (analyze src).a_ast with
    | None -> []
    | Some (_name, fields) ->
        let open Wax_wasm.Ast in
        let dctx = Wax_utils.Diagnostic.collector ~source:src () in
        let dead = ref [] in
        (* The branch not taken for a determined condition: [(@else …)] when true,
           the [(@then …)] body when false; nothing when it stays residual. *)
        let else_info b =
          Option.map (fun (b : (_, location) annotated) -> b.info) b
        in
        let branch cond then_loc else_loc =
          match Wax_wasm.Cond_specialize.eval dctx bindings cond with
          | True -> Option.iter (fun l -> dead := l :: !dead) else_loc
          | False -> dead := then_loc :: !dead
          | Residual _ -> ()
        in
        wat_iter_fields
          (fun field ->
            (match field.desc with
            | Text.Module_if_annotation { cond; then_fields; else_fields } ->
                branch cond then_fields.info (else_info else_fields)
            | _ -> ());
            wat_field_iter_instr
              (fun i ->
                match i.desc with
                | Text.If_annotation { cond; then_body; else_body } ->
                    branch cond then_body.info (else_info else_body)
                | _ -> ())
              field)
          fields;
        let offsets =
          List.concat_map
            (fun (l : Wax_utils.Ast.location) ->
              [ l.loc_start.pos_cnum; l.loc_end.pos_cnum ])
            !dead
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
          !dead

(* Semantic tokens for WAT: colour each index identifier by the kind of
   definition it resolves to, so functions, types, globals, locals and struct
   fields — all rendered the same by the grammar — are distinguished. Built from
   the name-resolution bindings ([Wax_wasm.Resolve]); labels have no matching
   token type in the legend and keep their grammar colour. Both symbolic ([$id])
   and numeric index tokens are classified. *)
let semantic_tokens_string ?(encoding = UTF16) src =
  let token_type : Wax_wasm.Resolve.kind -> string option = function
    | Func -> Some "function"
    | Type -> Some "type"
    | Field -> Some "property"
    | Param -> Some "parameter"
    | Local | Global | Memory | Table | Tag | Elem | Data -> Some "variable"
    | Label -> None
  in
  let toks =
    List.concat_map
      (fun (b : Wax_wasm.Resolve.binding) ->
        match token_type b.kind with
        | None -> []
        | Some ty ->
            let occ = b.defs @ b.uses in
            List.map (fun loc -> (loc, ty)) occ)
      (wat_bindings src)
  in
  let toks =
    List.filter
      (fun ((loc : Wax_utils.Ast.location), _) -> loc.loc_start.pos_cnum >= 0)
      toks
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
      | Some (line, char), Some (_, ec) when not (Hashtbl.mem seen (line, char))
        ->
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
