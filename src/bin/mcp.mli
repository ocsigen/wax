(** A minimal Model Context Protocol server exposing the Wax toolchain to AI
    assistants over stdio (see ADOPTION.md, Phase 6). SKELETON: newline-
    delimited framing rather than MCP's [Content-Length] headers. See {!mcp.ml}
    for the remaining TODOs. *)

type convert_result = {
  output : string option;
  encoding : string;
  diagnostics : Wax_utils.Diagnostic.entry list;
}
(** The result of a conversion. [output] is the converted module ([Some]) or
    [None] if the conversion failed, encoded per [encoding] — ["utf-8"] for text
    (wat/wax) output, or ["base64"] for a binary (wasm) module (JSON strings
    cannot carry raw bytes). [diagnostics] are the warnings emitted on success,
    or the errors on failure ([output = None]). *)

val serve :
  reference:(unit -> string) ->
  check:
    (format:string ->
    source:string ->
    (Wax_utils.Diagnostic.entry list, string) result) ->
  convert:
    (from_:string ->
    to_:string ->
    source:string ->
    (convert_result, string) result) ->
  unit ->
  unit
(** [serve ~reference ~check ~convert ()] runs the JSON-RPC read/dispatch loop
    on stdin/stdout until end of input. The toolchain-specific work is supplied
    by the callbacks so this module stays free of the parser instantiations:

    - [reference ()] returns the language-reference document served by the
      [wax_reference] tool (the generated docs/llms.txt).
    - [check ~format ~source] validates [source] in [format] ([wax] or [wat])
      and returns its collected diagnostics, or [Error msg] for an unsupported
      format. Backs the [wax_check] tool.
    - [convert ~from_ ~to_ ~source] converts [source] between formats ([wax],
      [wat], [wasm]), returning the output or [Error msg]. Backs the
      [wax_convert] tool. *)
