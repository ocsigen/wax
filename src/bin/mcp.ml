(* A minimal Model Context Protocol (MCP) server exposing the Wax toolchain to
   AI assistants over stdio. See ADOPTION.md, Phase 6: bundling this with the
   toolchain lets any MCP-capable assistant (Claude Code, Cursor, ...) learn Wax
   from `wax_reference` and self-check its output with `wax_check`, without the
   language being in its training data.

   SKELETON. Deliberately incomplete, with the design decisions the author
   should own left as TODOs:
     - Transport framing. Real MCP over stdio frames each JSON-RPC message with
       an LSP-style `Content-Length:` header. This skeleton uses newline-
       delimited JSON, which is enough to drive by hand or from a test but not
       wire-compatible with MCP clients. Replace {!read_message}/{!write} with
       header framing before shipping.
     - `wax_convert` is backed by [convert], which main.ml implements for now by
       shelling out to `wax convert` over temp files (robust — a malformed input
       cannot take the server down — but not the eventual in-memory path).
     - `wax_reference` returns whatever [reference] yields; main.ml embeds the
       generated docs/llms.txt there at build time (see docs/gen_llms.ml).

   The valuable, real part is `wax_check`: it runs the same parser + validator
   the CLI `check` command uses (via the [check] callback) and returns
   structured diagnostics an agent can act on. *)

module J = Yojson.Safe

type convert_result = { output : string; encoding : string }

(* Render a diagnostic's [Format]-printed message to a plain string. *)
let to_string pr =
  let b = Buffer.create 128 in
  let f = Format.formatter_of_buffer b in
  pr f ();
  Format.pp_print_flush f ();
  Buffer.contents b

(* A collected diagnostic as JSON. Line/column are 1-based / 0-based following
   the usual editor convention; byte offsets ([pos_cnum]) are included too since
   an agent applying a fix works on the raw bytes. *)
let diagnostic_to_json (e : Wax_utils.Diagnostic.entry) : J.t =
  let loc = Wax_utils.Diagnostic.entry_location e in
  let pos_col (p : Lexing.position) = p.pos_cnum - p.pos_bol in
  let severity =
    match Wax_utils.Diagnostic.entry_severity e with
    | Wax_utils.Diagnostic.Error -> "error"
    | Wax_utils.Diagnostic.Warning -> "warning"
  in
  let warning =
    match Wax_utils.Diagnostic.entry_warning e with
    | Some w -> `String (Wax_utils.Warning.name w)
    | None -> `Null
  in
  let hint =
    match Wax_utils.Diagnostic.entry_hint e with
    | Some pr -> `String (to_string pr)
    | None -> `Null
  in
  `Assoc
    [
      ("severity", `String severity);
      ("message", `String (to_string (Wax_utils.Diagnostic.entry_message e)));
      ("startLine", `Int loc.loc_start.pos_lnum);
      ("startColumn", `Int (pos_col loc.loc_start));
      ("endLine", `Int loc.loc_end.pos_lnum);
      ("endColumn", `Int (pos_col loc.loc_end));
      ("startOffset", `Int loc.loc_start.pos_cnum);
      ("endOffset", `Int loc.loc_end.pos_cnum);
      ("warning", warning);
      ("hint", hint);
    ]

(* The tool catalogue advertised by tools/list. The input schemas are JSON
   Schema, as MCP requires. *)
let tools : J.t =
  let string_prop desc =
    `Assoc [ ("type", `String "string"); ("description", `String desc) ]
  in
  let text_tool ~name ~description ~props ~required =
    `Assoc
      [
        ("name", `String name);
        ("description", `String description);
        ( "inputSchema",
          `Assoc
            [
              ("type", `String "object");
              ("properties", `Assoc props);
              ("required", `List (List.map (fun s -> `String s) required));
            ] );
      ]
  in
  `List
    [
      text_tool ~name:"wax_reference"
        ~description:
          "Return the Wax language reference (grammar, type system, CLI, and \
           worked examples) as one document, for use as context when writing \
           Wax."
        ~props:[] ~required:[];
      text_tool ~name:"wax_check"
        ~description:
          "Validate a Wax or WAT snippet and return its diagnostics (type \
           errors, validation errors, lints) as structured JSON. Use this to \
           check Wax you produce before returning it."
        ~props:
          [
            ("format", string_prop "Input format: \"wax\" (default) or \"wat\".");
            ("source", string_prop "The source text to validate.");
          ]
        ~required:[ "source" ];
      text_tool ~name:"wax_convert"
        ~description:
          "Convert a module between Wax, WAT and WASM. Text output (wat/wax) \
           is returned as UTF-8; binary output (wasm) is base64-encoded."
        ~props:
          [
            ("from", string_prop "Input format: \"wax\", \"wat\" or \"wasm\".");
            ("to", string_prop "Output format: \"wax\", \"wat\" or \"wasm\".");
            ("source", string_prop "The source text to convert.");
          ]
        ~required:[ "from"; "to"; "source" ];
    ]

(* Wrap a plain-text payload in an MCP tool result. *)
let text_result ?(is_error = false) text : J.t =
  `Assoc
    [
      ( "content",
        `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ] );
      ("isError", `Bool is_error);
    ]

let member name = function
  | `Assoc l -> ( try List.assoc name l with Not_found -> `Null)
  | _ -> `Null

let string_member name obj =
  match member name obj with `String s -> Some s | _ -> None

(* Dispatch a tools/call to the matching handler. *)
let call_tool ~reference ~check ~convert params : J.t =
  let name = string_member "name" params in
  let args = member "arguments" params in
  match name with
  | Some "wax_reference" -> text_result (reference ())
  | Some "wax_check" -> (
      match string_member "source" args with
      | None -> text_result ~is_error:true "wax_check: missing \"source\""
      | Some source -> (
          let format =
            Option.value ~default:"wax" (string_member "format" args)
          in
          match check ~format ~source with
          | Error msg -> text_result ~is_error:true ("wax_check: " ^ msg)
          | Ok entries ->
              let diags = `List (List.map diagnostic_to_json entries) in
              let ok = entries = [] in
              text_result
                (J.to_string
                   (`Assoc [ ("valid", `Bool ok); ("diagnostics", diags) ]))))
  | Some "wax_convert" -> (
      match
        ( string_member "from" args,
          string_member "to" args,
          string_member "source" args )
      with
      | Some from_, Some to_, Some source -> (
          match convert ~from_ ~to_ ~source with
          | Error msg -> text_result ~is_error:true ("wax_convert: " ^ msg)
          | Ok { output; encoding } ->
              text_result
                (J.to_string
                   (`Assoc
                      [
                        ("format", `String to_);
                        ("encoding", `String encoding);
                        ("output", `String output);
                      ])))
      | _ ->
          text_result ~is_error:true
            "wax_convert: requires \"from\", \"to\" and \"source\"")
  | Some other -> text_result ~is_error:true ("unknown tool: " ^ other)
  | None -> text_result ~is_error:true "tools/call: missing \"name\""

(* JSON-RPC 2.0 result / error envelopes. *)
let ok_response id result : J.t =
  `Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ]

let error_response id code message : J.t =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id);
      ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]);
    ]

let server_info : J.t =
  `Assoc
    [
      ( "serverInfo",
        `Assoc [ ("name", `String "wax"); ("version", `String "0.0.0") ] );
      (* Advertise MCP protocol + a tools capability. Bump protocolVersion to
         match the client during the initialize handshake if needed. *)
      ("protocolVersion", `String "2024-11-05");
      ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
    ]

(* Handle one parsed request. Notifications (no [id]) get no reply. *)
let handle ~reference ~check ~convert (msg : J.t) : J.t option =
  let id = member "id" msg in
  let meth = string_member "method" msg in
  let params = member "params" msg in
  match meth with
  | Some "initialize" -> Some (ok_response id server_info)
  | Some "tools/list" -> Some (ok_response id (`Assoc [ ("tools", tools) ]))
  | Some "tools/call" ->
      Some (ok_response id (call_tool ~reference ~check ~convert params))
  | Some "notifications/initialized" | Some "ping" ->
      if id = `Null then None else Some (ok_response id (`Assoc []))
  | Some other ->
      if id = `Null then None
      else Some (error_response id (-32601) ("method not found: " ^ other))
  | None -> None

(* TODO: real MCP framing is `Content-Length: N\r\n\r\n<body>`. This reads one
   JSON object per line, which is enough for manual testing. *)
let read_message () = In_channel.input_line stdin

let write (msg : J.t) =
  J.to_channel stdout msg;
  output_char stdout '\n';
  flush stdout

let serve ~reference ~check ~convert () =
  let rec loop () =
    match read_message () with
    | None -> ()
    | Some "" -> loop ()
    | Some line ->
        (match J.from_string line with
        | msg -> Option.iter write (handle ~reference ~check ~convert msg)
        | exception _ -> write (error_response `Null (-32700) "parse error"));
        loop ()
  in
  loop ()
