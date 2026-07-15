(* A Language Server Protocol server for Wax (and Wasm text), speaking JSON-RPC
   over stdin/stdout. It is a thin protocol layer over {!Wax_editor}: it keeps a
   store of open documents, maps each LSP request to the matching [Wax_editor]
   function, and pushes diagnostics on open/change. All the analysis lives in
   [Wax_editor] (shared with the VS Code extension's in-process wasm build); this
   module only translates between the protocol and those pure functions.

   The loop is synchronous — one request at a time, no concurrency — which suits
   a single editor session and the synchronous analysis. Document sync is [Full]:
   each change carries the whole buffer, which is exactly what [Wax_editor]'s
   source-keyed analysis expects. The position encoding is negotiated at
   [initialize]: UTF-8 when the client offers it (bytes are [Wax_editor]'s
   internal unit, so the conversion is the identity), otherwise UTF-16 (the LSP
   default and mandatory baseline); the chosen encoding is threaded to every
   [Wax_editor] call. *)

open Lsp.Types

(* --- transport: blocking JSON-RPC packets over stdin/stdout --- *)

(* [Lsp.Io.Make] is written against an IO monad; a synchronous server uses the
   identity monad, so [read]/[write] are ordinary blocking calls. *)
module Id = struct
  type 'a t = 'a

  let return x = x
  let raise = raise

  module O = struct
    let ( let+ ) x f = f x
    let ( let* ) x f = f x
  end
end

(* Read [len] bytes into [buf] at [off], retrying across [EINTR]. *)
let rec read_retry fd buf off len =
  try Unix.read fd buf off len
  with Unix.Unix_error (Unix.EINTR, _, _) -> read_retry fd buf off len

(* Two transports over the same framing. [Io_fd] reads a raw file descriptor
   *without over-reading past the current frame* (header a byte at a time, then
   the exact body length), so [Unix.select] on the fd is an accurate "more input
   pending?" test — the debounce in [run_native] relies on that. [Io_chan] reads
   an ordinary [in_channel]; it uses no [Unix] and backs [run_fallback], for
   backends without a working [Unix.select] (js_of_ocaml / wasm_of_ocaml).
   Writing is identical (buffered [out_channel], flushed per packet), so
   [send_packet] can use either. *)
module Io_fd =
  Lsp.Io.Make
    (Id)
    (struct
      type input = Unix.file_descr
      type output = out_channel

      (* A line up to (not including) '\n', keeping any trailing '\r' — the
         shape [Lsp.Io]'s header parser expects. [None] at end of input. *)
      let read_line fd =
        let buf = Buffer.create 64 in
        let b = Bytes.create 1 in
        let rec go () =
          match read_retry fd b 0 1 with
          | 0 ->
              if Buffer.length buf = 0 then None else Some (Buffer.contents buf)
          | _ ->
              let c = Bytes.get b 0 in
              if c = '\n' then Some (Buffer.contents buf)
              else (
                Buffer.add_char buf c;
                go ())
        in
        go ()

      let read_exactly fd n =
        let b = Bytes.create n in
        let rec go off =
          if off = n then Some (Bytes.unsafe_to_string b)
          else
            match read_retry fd b off (n - off) with
            | 0 -> None
            | k -> go (off + k)
        in
        if n = 0 then Some "" else go 0

      let write oc segments =
        List.iter (output_string oc) segments;
        flush oc
    end)

module Io_chan =
  Lsp.Io.Make
    (Id)
    (struct
      type input = in_channel
      type output = out_channel

      let read_line ic = try Some (input_line ic) with End_of_file -> None

      let read_exactly ic n =
        let b = Bytes.create n in
        try
          really_input ic b 0 n;
          Some (Bytes.unsafe_to_string b)
        with End_of_file -> None

      let write oc segments =
        List.iter (output_string oc) segments;
        flush oc
    end)

let send_packet packet = Io_fd.write stdout packet

let send_notification n =
  send_packet
    (Jsonrpc.Packet.Notification (Lsp.Server_notification.to_jsonrpc n))

(* --- open-document store, keyed by the URI's string form --- *)

let documents : (string, string) Hashtbl.t = Hashtbl.create 16
let doc_key uri = Lsp.Uri.to_string uri
let get_doc uri = Hashtbl.find_opt documents (doc_key uri)
let set_doc uri text = Hashtbl.replace documents (doc_key uri) text
let remove_doc uri = Hashtbl.remove documents (doc_key uri)

(* Diagnostics debounce: a document edited by [didChange] is marked dirty rather
   than re-checked on the spot, and (in [run_native]) its diagnostics are
   published only once the client has been quiet for [diagnostics_debounce]
   seconds. This coalesces a burst of edits into one analysis, so fast typing on
   a large file does not re-check the whole buffer on every keystroke. The
   deadline itself is a local of [run_native]; [mark_dirty] only records which
   documents are pending (so it needs no clock, and [run_fallback] can flush
   them eagerly). *)
let diagnostics_debounce = 0.15
let dirty : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Wasm text is served by the [*_wat_string] analysis; everything else is Wax. *)
let is_wat uri = Filename.check_suffix (Lsp.Uri.to_string uri) ".wat"

(* The position encoding negotiated at [initialize]: the unit the client counts
   line offsets in. UTF-16 is the mandatory default; UTF-8 is used only when the
   client offers it. Set once, before any request is served, so [Wax_editor]'s
   coordinate conversions match what the client sends and expects. *)
let encoding = ref Wax_editor.UTF16

let lsp_encoding = function
  | Wax_editor.UTF8 -> PositionEncodingKind.UTF8
  | Wax_editor.UTF16 -> PositionEncodingKind.UTF16

(* The conditional-compilation defines (the editor's `wax.define`, mirroring the
   `-D` CLI flag), read from configuration at startup and on change. Diagnostics
   and completion specialize to them; empty leaves the ordinary all-paths check. *)
let defines = ref ([] : string list)

(* Extract the `define` string list from a settings object, accepting either
   [{ "define": [...] }] (initialization options) or [{ "wax": { "define": … } }]
   (a namespaced configuration section). Absent or malformed yields the empty
   list, which clears any previous defines. *)
let defines_of_settings (json : Jsonrpc.Json.t) =
  let assoc = function `Assoc l -> l | _ -> [] in
  let strings = function
    | `List items ->
        List.filter_map (function `String s -> Some s | _ -> None) items
    | _ -> []
  in
  let top = assoc json in
  match List.assoc_opt "define" top with
  | Some v -> strings v
  | None -> (
      match List.assoc_opt "wax" top with
      | Some w -> (
          match List.assoc_opt "define" (assoc w) with
          | Some v -> strings v
          | None -> [])
      | None -> [])

(* --- coordinate mapping between LSP and Wax_editor --- *)

let position line character = Position.create ~line ~character

let range_of_location src (loc : Wax_utils.Ast.location) =
  let sl, sc = Wax_editor.position ~encoding:!encoding src loc.loc_start in
  let el, ec = Wax_editor.position ~encoding:!encoding src loc.loc_end in
  Range.create ~start:(position sl sc) ~end_:(position el ec)

(* The span of the whole buffer, for a full-document formatting edit. The end
   column is measured in the negotiated encoding: bytes under UTF-8, UTF-16 code
   units under UTF-16. *)
let full_range text =
  let rec last_line i line start =
    if i >= String.length text then (line, start)
    else if text.[i] = '\n' then last_line (i + 1) (line + 1) (i + 1)
    else last_line (i + 1) line start
  in
  let line, start = last_line 0 0 0 in
  let last = String.sub text start (String.length text - start) in
  let width =
    match !encoding with
    | Wax_editor.UTF8 -> String.length last
    | Wax_editor.UTF16 -> Wax_utils.Unicode.utf16_length last
  in
  Range.create ~start:(position 0 0) ~end_:(position line width)

(* --- kind mappings from Wax_editor's kind words to LSP enums --- *)

let symbol_kind = function
  | "function" -> SymbolKind.Function
  | "variable" -> SymbolKind.Variable
  | "type" -> SymbolKind.Struct
  | "event" -> SymbolKind.Event
  | "memory" | "table" | "data" -> SymbolKind.Variable
  | "array" -> SymbolKind.Array
  | "namespace" -> SymbolKind.Namespace
  | _ -> SymbolKind.Variable

let completion_item_kind = function
  | "function" -> CompletionItemKind.Function
  | "method" -> CompletionItemKind.Method
  | "field" -> CompletionItemKind.Field
  | "variable" | "local" | "memory" | "table" | "data" ->
      CompletionItemKind.Variable
  | "parameter" -> CompletionItemKind.Variable
  | "type" -> CompletionItemKind.Struct
  | "event" -> CompletionItemKind.Event
  | "keyword" -> CompletionItemKind.Keyword
  | "namespace" -> CompletionItemKind.Module
  | "array" -> CompletionItemKind.Variable
  | _ -> CompletionItemKind.Text

(* --- diagnostics (pushed on open/change) --- *)

(* The hosted documentation of the [-W] lints, for a diagnostic's
   [codeDescription] (the "learn more" link on its code). One page lists every
   warning with its meaning and how to configure it. *)
let warning_doc_url = "https://ocsigen.org/wax/cli.html#warnings"

let diagnostic_of_diag uri src (d : Wax_editor.diag) =
  let severity =
    match d.severity with
    | Wax_utils.Diagnostic.Error -> DiagnosticSeverity.Error
    | Warning -> DiagnosticSeverity.Warning
  in
  (* Fold the hint into the message; editors show one message per diagnostic. *)
  let message =
    match d.hint with Some h -> d.message ^ "\n" ^ h | None -> d.message
  in
  let relatedInformation =
    List.map
      (fun (msg, loc) ->
        DiagnosticRelatedInformation.create
          ~location:(Location.create ~uri ~range:(range_of_location src loc))
          ~message:msg)
      d.related
  in
  (* A lint that flags removable/unreachable code is tagged [Unnecessary], so
     the client fades it (VS Code's greyed-out dead code). *)
  let tags =
    if d.unnecessary then Some [ DiagnosticTag.Unnecessary ] else None
  in
  (* When the diagnostic carries a lint name, link its code to the docs. *)
  let codeDescription =
    Option.map
      (fun _ ->
        CodeDescription.create ~href:(Lsp.Uri.of_string warning_doc_url))
      d.warning
  in
  Diagnostic.create
    ~range:(range_of_location src d.location)
    ~severity ~source:"wax"
    ?code:(Option.map (fun w -> `String w) d.warning)
    ?codeDescription ?tags ~message:(`String message) ~relatedInformation ()

let publish_diagnostics uri src =
  let diags =
    if is_wat uri then Wax_editor.check_wat_string src
    else Wax_editor.check_string_with_defines src !defines
  in
  let diagnostics = List.map (diagnostic_of_diag uri src) diags in
  send_notification
    (Lsp.Server_notification.PublishDiagnostics
       (PublishDiagnosticsParams.create ~uri ~diagnostics ()))

(* Record a document as needing a re-check. *)
let mark_dirty uri = Hashtbl.replace dirty (doc_key uri) ()

(* Publish diagnostics for every dirty document, then clear the pending set. *)
let flush_dirty () =
  Hashtbl.iter
    (fun key () ->
      match Hashtbl.find_opt documents key with
      | Some src -> publish_diagnostics (Lsp.Uri.of_string key) src
      | None -> ())
    dirty;
  Hashtbl.reset dirty

(* --- request handlers --- *)

let hover_markup h_type =
  `MarkupContent
    (MarkupContent.create ~kind:MarkupKind.Markdown
       ~value:(Printf.sprintf "```wax\n%s\n```" h_type))

let rec document_symbol src (s : Wax_editor.sym) =
  DocumentSymbol.create ~name:s.s_name ~kind:(symbol_kind s.s_kind)
    ~range:(range_of_location src s.s_range)
    ~selectionRange:(range_of_location src s.s_selection)
    ~children:(List.map (document_symbol src) s.s_children)
    ()

let completion_item (c : Wax_editor.completion) =
  let detail = if c.k_detail = "" then None else Some c.k_detail in
  CompletionItem.create ~label:c.k_name
    ~kind:(completion_item_kind c.k_kind)
    ?detail ()

(* Build one nested {!SelectionRange.t} from a chain of spans ordered
   innermost-first, so each range's [parent] is the next-wider span. *)
let selection_range chain =
  List.fold_left
    (fun parent (sl, sc, el, ec) ->
      let range = Range.create ~start:(position sl sc) ~end_:(position el ec) in
      Some (SelectionRange.create ~range ?parent ()))
    None (List.rev chain)

(* The semantic-token legend: the token types [Wax_editor.semantic_tokens_string]
   emits, in the order their indices are encoded below. *)
let semantic_token_types =
  [ "namespace"; "type"; "function"; "variable"; "parameter"; "property" ]

let semantic_legend =
  SemanticTokensLegend.create ~tokenModifiers:[]
    ~tokenTypes:semantic_token_types

(* Encode the (line, char, length, type) tokens into the LSP delta format: each
   token is five ints relative to the previous emitted token. A token whose type
   is not in the legend is skipped without advancing the delta baseline. *)
let semantic_data toks =
  let index t =
    let rec find i = function
      | [] -> None
      | x :: _ when x = t -> Some i
      | _ :: r -> find (i + 1) r
    in
    find 0 semantic_token_types
  in
  let rec go prev_line prev_char = function
    | [] -> []
    | (tok : Wax_editor.sem_token) :: rest -> (
        match index tok.st_type with
        | None -> go prev_line prev_char rest
        | Some ti ->
            let dl = tok.st_line - prev_line in
            let dc = if dl = 0 then tok.st_char - prev_char else tok.st_char in
            dl :: dc :: tok.st_len :: ti :: 0 :: go tok.st_line tok.st_char rest
        )
  in
  Array.of_list (go 0 0 toks)

let server_capabilities () =
  ServerCapabilities.create ~positionEncoding:(lsp_encoding !encoding)
    ~textDocumentSync:
      (`TextDocumentSyncOptions
         (TextDocumentSyncOptions.create ~openClose:true
            ~change:TextDocumentSyncKind.Full ()))
    ~hoverProvider:(`Bool true) ~definitionProvider:(`Bool true)
    ~typeDefinitionProvider:(`Bool true) ~referencesProvider:(`Bool true)
    ~documentHighlightProvider:(`Bool true) ~documentSymbolProvider:(`Bool true)
    ~renameProvider:
      (`RenameOptions (RenameOptions.create ~prepareProvider:true ()))
    ~completionProvider:
      (CompletionOptions.create ~triggerCharacters:[ "."; ":" ] ())
    ~signatureHelpProvider:
      (SignatureHelpOptions.create ~triggerCharacters:[ "("; "," ] ())
    ~inlayHintProvider:(`Bool true) ~foldingRangeProvider:(`Bool true)
    ~selectionRangeProvider:(`Bool true)
    ~documentFormattingProvider:(`Bool true)
    ~semanticTokensProvider:
      (`SemanticTokensOptions
         (SemanticTokensOptions.create ~legend:semantic_legend
            ~full:(`Bool true) ()))
    ()

(* Dispatch a typed request to the matching [Wax_editor] function. The result
   type is fixed by the GADT constructor, so each branch produces exactly what
   {!Lsp.Client_request.yojson_of_result} expects. Requests we do not advertise
   fall through to a method-not-found error. *)
let on_request (type r) (r : r Lsp.Client_request.t) : r =
  let with_doc uri f =
    match get_doc uri with None -> None | Some src -> f src
  in
  match r with
  | Lsp.Client_request.Initialize params ->
      (* Pick UTF-8 when the client offers it, otherwise keep the UTF-16
         default (which every client supports); advertise the choice back. *)
      (match params.capabilities.general with
      | Some { positionEncodings = Some encs; _ }
        when List.mem PositionEncodingKind.UTF8 encs ->
          encoding := Wax_editor.UTF8
      | _ -> ());
      (* Conditional-compilation defines, if the client passed any as
         initialization options. Live updates come via didChangeConfiguration. *)
      Option.iter
        (fun j -> defines := defines_of_settings j)
        params.initializationOptions;
      InitializeResult.create ~capabilities:(server_capabilities ())
        ~serverInfo:(InitializeResult.create_serverInfo ~name:"wax-lsp" ())
        ()
  | Lsp.Client_request.Shutdown -> ()
  | Lsp.Client_request.TextDocumentHover { textDocument; position; _ } ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let hover =
            if is_wat uri then Wax_editor.hover_wat_string
            else Wax_editor.hover_string
          in
          match
            hover ~encoding:!encoding src position.line position.character
          with
          | None -> None
          | Some h ->
              Some
                (Hover.create ~contents:(hover_markup h.h_type)
                   ~range:(range_of_location src h.h_range)
                   ()))
  | Lsp.Client_request.TextDocumentDefinition { textDocument; position; _ } ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let definition =
            if is_wat uri then Wax_editor.definition_wat_string
            else Wax_editor.definition_string
          in
          match
            definition ~encoding:!encoding src position.line position.character
          with
          | [] -> None
          | locs ->
              Some
                (`Location
                   (List.map
                      (fun loc ->
                        Location.create ~uri ~range:(range_of_location src loc))
                      locs)))
  | Lsp.Client_request.TextDocumentTypeDefinition { textDocument; position; _ }
    ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let type_definition =
            if is_wat uri then Wax_editor.type_definition_wat_string
            else Wax_editor.type_definition_string
          in
          match
            type_definition ~encoding:!encoding src position.line
              position.character
          with
          | [] -> None
          | locs ->
              Some
                (`Location
                   (List.map
                      (fun loc ->
                        Location.create ~uri ~range:(range_of_location src loc))
                      locs)))
  | Lsp.Client_request.TextDocumentReferences { textDocument; position; _ } ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let references =
            if is_wat uri then Wax_editor.references_wat_string
            else Wax_editor.references_string
          in
          Some
            (List.map
               (fun loc ->
                 Location.create ~uri ~range:(range_of_location src loc))
               (references ~encoding:!encoding src position.line
                  position.character)))
  | Lsp.Client_request.TextDocumentHighlight { textDocument; position; _ } ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let references =
            if is_wat uri then Wax_editor.references_wat_string
            else Wax_editor.references_string
          in
          Some
            (List.map
               (fun loc ->
                 DocumentHighlight.create ~range:(range_of_location src loc) ())
               (references ~encoding:!encoding src position.line
                  position.character)))
  | Lsp.Client_request.TextDocumentPrepareRename { textDocument; position; _ }
    ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let rename_prepare =
            if is_wat uri then Wax_editor.rename_prepare_wat_string
            else Wax_editor.rename_prepare_string
          in
          Option.map (range_of_location src)
            (rename_prepare ~encoding:!encoding src position.line
               position.character))
  | Lsp.Client_request.TextDocumentRename { textDocument; position; newName; _ }
    ->
      let uri = textDocument.uri in
      let edits =
        match get_doc uri with
        | None -> []
        | Some src ->
            let edit (loc, newText) =
              TextEdit.create ~range:(range_of_location src loc) ~newText
            in
            if is_wat uri then
              List.map edit
                (Wax_editor.rename_wat_string ~encoding:!encoding src
                   position.line position.character newName)
            else (
              match
                Wax_editor.rename_string ~encoding:!encoding src position.line
                  position.character newName
              with
              | Wax_editor.Rename_conflict message ->
                  Jsonrpc.Response.Error.raise
                    (Jsonrpc.Response.Error.make
                       ~code:Jsonrpc.Response.Error.Code.RequestFailed ~message
                       ())
              | Wax_editor.Rename_edits edits -> List.map edit edits)
      in
      WorkspaceEdit.create ~changes:[ (uri, edits) ] ()
  | Lsp.Client_request.DocumentSymbol { textDocument; _ } ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let syms =
            if is_wat uri then Wax_editor.symbols_wat_string src
            else Wax_editor.symbols_string src
          in
          Some (`DocumentSymbol (List.map (document_symbol src) syms)))
  | Lsp.Client_request.TextDocumentCompletion { textDocument; position; _ } ->
      let uri = textDocument.uri in
      if is_wat uri then None
      else
        with_doc uri (fun src ->
            let items =
              Wax_editor.completion_string ~encoding:!encoding src position.line
                position.character !defines
            in
            Some (`List (List.map completion_item items)))
  | Lsp.Client_request.SignatureHelp { textDocument; position; _ } -> (
      let empty = SignatureHelp.create ~signatures:[] () in
      let uri = textDocument.uri in
      match get_doc uri with
      | None -> empty
      | Some src -> (
          let signature_help =
            if is_wat uri then Wax_editor.signature_help_wat_string
            else Wax_editor.signature_help_string
          in
          match
            signature_help ~encoding:!encoding src position.line
              position.character
          with
          | None -> empty
          | Some (label, ranges, active) ->
              let parameters =
                List.map
                  (fun (s, e) ->
                    ParameterInformation.create ~label:(`Offset (s, e)) ())
                  ranges
              in
              let info =
                SignatureInformation.create ~label ~parameters
                  ~activeParameter:(Some active) ()
              in
              SignatureHelp.create ~signatures:[ info ] ~activeSignature:0
                ~activeParameter:(Some active) ()))
  | Lsp.Client_request.InlayHint { textDocument; _ } ->
      let uri = textDocument.uri in
      if is_wat uri then None
      else
        with_doc uri (fun src ->
            Some
              (List.map
                 (fun (h : Wax_editor.inlay) ->
                   let line, character =
                     Wax_editor.position ~encoding:!encoding src h.n_pos
                   in
                   InlayHint.create ~position:(position line character)
                     ~label:(`String h.n_label) ~kind:InlayHintKind.Type ())
                 (Wax_editor.inlays_string src)))
  | Lsp.Client_request.TextDocumentFoldingRange { textDocument; _ } ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let folding =
            if is_wat uri then Wax_editor.folding_wat_string
            else Wax_editor.folding_string
          in
          Some
            (List.map
               (fun (startLine, endLine, kind) ->
                 let kind =
                   match kind with
                   | "comment" -> Some FoldingRangeKind.Comment
                   | "imports" -> Some FoldingRangeKind.Imports
                   | _ -> Some FoldingRangeKind.Region
                 in
                 FoldingRange.create ~startLine ~endLine ?kind ())
               (folding src)))
  | Lsp.Client_request.SelectionRange { textDocument; positions; _ } -> (
      let uri = textDocument.uri in
      match get_doc uri with
      | None ->
          List.map
            (fun (p : Position.t) ->
              SelectionRange.create ~range:(Range.create ~start:p ~end_:p) ())
            positions
      | Some src ->
          let selection_range_chain =
            if is_wat uri then Wax_editor.selection_range_wat_string
            else Wax_editor.selection_range_string
          in
          List.map
            (fun (p : Position.t) ->
              let chain =
                selection_range_chain ~encoding:!encoding src p.line p.character
              in
              match selection_range chain with
              | Some sr -> sr
              | None ->
                  SelectionRange.create
                    ~range:(Range.create ~start:p ~end_:p)
                    ())
            positions)
  | Lsp.Client_request.SemanticTokensFull { textDocument; _ } ->
      let uri = textDocument.uri in
      with_doc uri (fun src ->
          let semantic_tokens =
            if is_wat uri then Wax_editor.semantic_tokens_wat_string
            else Wax_editor.semantic_tokens_string
          in
          Some
            (SemanticTokens.create
               ~data:(semantic_data (semantic_tokens ~encoding:!encoding src))
               ()))
  | Lsp.Client_request.TextDocumentFormatting { textDocument; _ } -> (
      let uri = textDocument.uri in
      match get_doc uri with
      | None -> None
      | Some src -> (
          let formatted =
            if is_wat uri then Wax_editor.format_wat_string src
            else Wax_editor.format_string src
          in
          match formatted with
          | Error _ -> None
          | Ok text ->
              Some [ TextEdit.create ~range:(full_range src) ~newText:text ]))
  | _ ->
      Jsonrpc.Response.Error.raise
        (Jsonrpc.Response.Error.make
           ~code:Jsonrpc.Response.Error.Code.MethodNotFound
           ~message:"unsupported request" ())

(* --- notification handlers (document sync + diagnostics) --- *)

let on_notification (n : Lsp.Client_notification.t) =
  match n with
  | Lsp.Client_notification.TextDocumentDidOpen { textDocument } ->
      (* Open is a one-off, not a burst: publish at once for instant feedback. *)
      set_doc textDocument.uri textDocument.text;
      publish_diagnostics textDocument.uri textDocument.text
  | Lsp.Client_notification.TextDocumentDidChange
      { textDocument; contentChanges } -> (
      (* Full sync: the last change event carries the entire new buffer. The
         re-check is debounced (see [mark_dirty] / [run]) so a run of edits
         coalesces into one analysis. *)
      match List.rev contentChanges with
      | { text; _ } :: _ ->
          set_doc textDocument.uri text;
          mark_dirty textDocument.uri
      | [] -> ())
  | Lsp.Client_notification.TextDocumentDidClose { textDocument } ->
      remove_doc textDocument.uri;
      Hashtbl.remove dirty (doc_key textDocument.uri);
      (* Clear the editor's diagnostics for a closed document. *)
      send_notification
        (Lsp.Server_notification.PublishDiagnostics
           (PublishDiagnosticsParams.create ~uri:textDocument.uri
              ~diagnostics:[] ()))
  | Lsp.Client_notification.ChangeConfiguration { settings } ->
      (* Re-read the defines and re-check every open document against them. *)
      defines := defines_of_settings settings;
      Hashtbl.iter
        (fun key src -> publish_diagnostics (Lsp.Uri.of_string key) src)
        documents
  | Lsp.Client_notification.Exit -> exit 0
  | _ -> ()

(* --- main loop --- *)

let handle_request (req : Jsonrpc.Request.t) =
  match Lsp.Client_request.of_jsonrpc req with
  | Error _ ->
      send_packet
        (Jsonrpc.Packet.Response
           (Jsonrpc.Response.error req.id
              (Jsonrpc.Response.Error.make
                 ~code:Jsonrpc.Response.Error.Code.InvalidRequest
                 ~message:"could not decode request" ())))
  | Ok (Lsp.Client_request.E r) ->
      let response =
        try
          Jsonrpc.Response.ok req.id
            (Lsp.Client_request.yojson_of_result r (on_request r))
        with
        | Jsonrpc.Response.Error.E e -> Jsonrpc.Response.error req.id e
        | exn ->
            Jsonrpc.Response.error req.id
              (Jsonrpc.Response.Error.make
                 ~code:Jsonrpc.Response.Error.Code.InternalError
                 ~message:(Printexc.to_string exn) ())
      in
      send_packet (Jsonrpc.Packet.Response response)

let handle_notification (n : Jsonrpc.Notification.t) =
  match Lsp.Client_notification.of_jsonrpc n with
  | Error _ -> ()
  | Ok notif -> ( try on_notification notif with _ -> ())

let dispatch packet =
  match packet with
  | Jsonrpc.Packet.Request req -> handle_request req
  | Jsonrpc.Packet.Notification n -> handle_notification n
  | Jsonrpc.Packet.Response _ | Jsonrpc.Packet.Batch_response _
  | Jsonrpc.Packet.Batch_call _ ->
      ()

(* The native loop: read from the raw fd (never [Stdlib.stdin], whose buffering
   would both swallow bytes the fd read expects and hide pending input from
   [select]) and debounce diagnostics. The publish deadline is a local: after a
   packet leaves a document dirty it is (re)armed [diagnostics_debounce] seconds
   out, so a continuing burst keeps deferring; when [select] times out with the
   client quiet, the coalesced diagnostics are published. *)
let run_native () =
  set_binary_mode_out stdout true;
  let fd = Unix.stdin in
  let rec loop deadline =
    let timeout =
      match deadline with
      | None -> -1.0 (* nothing pending: block until input arrives *)
      | Some t -> Float.max 0. (t -. Unix.gettimeofday ())
    in
    match
      try Some (Unix.select [ fd ] [] [] timeout)
      with Unix.Unix_error (Unix.EINTR, _, _) -> None
    with
    | None -> loop deadline (* interrupted before the timeout: retry *)
    | Some ([], _, _) ->
        (* Timed out (only reachable with a deadline set): the quiet window
           elapsed, so publish the coalesced diagnostics. *)
        flush_dirty ();
        loop None
    | Some _ -> (
        (* A malformed packet (bad JSON, or params that are not a structured
           value) makes [read] raise; the frame has already been consumed, so
           drop it and carry on rather than crashing the session. *)
        match try `Packet (Io_fd.read fd) with _ -> `Skip with
        | `Skip -> loop deadline
        | `Packet None -> flush_dirty () (* EOF: publish pending, then stop *)
        | `Packet (Some packet) ->
            dispatch packet;
            (* Arm/refresh the window while anything is pending. *)
            let deadline =
              if Hashtbl.length dirty > 0 then
                Some (Unix.gettimeofday () +. diagnostics_debounce)
              else deadline
            in
            loop deadline)
  in
  loop None

(* The fallback loop, for backends without a working [Unix.select]
   (js_of_ocaml / wasm_of_ocaml, where the server is linked into the wasm CLI
   but rarely run): a plain blocking read over an [in_channel], publishing
   diagnostics eagerly (no debounce) after each message. *)
let run_fallback () =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let rec loop () =
    match try `Packet (Io_chan.read stdin) with _ -> `Skip with
    | `Skip -> loop ()
    | `Packet None -> () (* EOF *)
    | `Packet (Some packet) ->
        dispatch packet;
        flush_dirty ();
        loop ()
  in
  loop ()

let run () =
  match Sys.backend_type with
  | Sys.Other _ -> run_fallback () (* js_of_ocaml / wasm_of_ocaml *)
  | Sys.Native | Sys.Bytecode -> run_native ()
