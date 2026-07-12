The 'mcp' subcommand serves the toolchain to AI assistants over MCP, as
newline-delimited JSON-RPC on stdin/stdout. Requests here are fixture files
(one JSON object per line); responses are filtered to keep the assertions
stable, since the full tool schemas and the embedded reference are large.

initialize returns the server info and protocol version:

  $ wax mcp < init.json | grep -o '"serverInfo":{[^}]*}'
  "serverInfo":{"name":"wax","version":"0.0.0"}

tools/list advertises the three tools:

  $ wax mcp < list.json | grep -o '"name":"wax_[a-z_]*"'
  "name":"wax_reference"
  "name":"wax_check"
  "name":"wax_convert"

wax_check on valid Wax reports no problems (the result is a JSON string, so its
quotes are escaped in the transport):

  $ wax mcp < check-ok.json | grep -o '\\"valid\\":[a-z]*'
  \"valid\":true

wax_check on invalid Wax reports it as a diagnostic, without failing the server:

  $ wax mcp < check-bad.json | grep -oE '\\"(valid|severity)\\":\\?"?[a-z]*'
  \"valid\":false
  \"severity\":\"error

wax_convert compiles Wax to WAT (text, utf-8):

  $ wax mcp < convert-wat.json | grep -oE '\\"(format|encoding)\\":\\"[a-z0-9-]*'
  \"format\":\"wat
  \"encoding\":\"utf-8
  $ wax mcp < convert-wat.json | grep -oc 'i32.mul'
  1

wax_convert to the binary format returns base64:

  $ wax mcp < convert-wasm.json | grep -oE '\\"encoding\\":\\"[a-z0-9]*'
  \"encoding\":\"base64

wax_convert on invalid input returns structured diagnostics (not a module) and
keeps the server up:

  $ wax mcp < convert-bad.json | grep -o '"isError":true'
  "isError":true
  $ wax mcp < convert-bad.json | grep -oE '\\"severity\\":\\"error'
  \"severity\":\"error

wax_reference returns the embedded language reference (not an error):

  $ wax mcp < ref.json | grep -o '"isError":false'
  "isError":false
  $ wax mcp < ref.json | grep -oc 'Wax language reference'
  1
