The `wax lsp` subcommand is a JSON-RPC language server over stdin/stdout, a thin
protocol layer over the same analysis the VS Code extension uses. Rather than
pin a golden of the (large, evolving) capability and completion payloads, drive
a scripted session and assert the salient facts of each response — this proves
the framing, the request dispatch, and the coordinate mapping end to end.

A small, well-formed Wax module to analyze:

  $ cat > demo.wax <<'WAX'
  > fn add(a: i32, b: i32) -> i32 {
  >   let c = a + b;
  >   c;
  > }
  > WAX

Send initialize, open the document, then one request of each main kind, and
finally shut down. The driver frames each message with its `Content-Length`
header, reads the framed replies back, and prints a compact summary:

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b = json.dumps(o).encode()
  >     return b"Content-Length: %d\r\n\r\n%s" % (len(b), b)
  > uri = "file:///demo.wax"
  > src = open("demo.wax").read()
  > td = {"uri": uri}
  > session = [
  >     {"jsonrpc":"2.0","id":1,"method":"initialize",
  >      "params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >     {"jsonrpc":"2.0","method":"initialized","params":{}},
  >     {"jsonrpc":"2.0","method":"textDocument/didOpen",
  >      "params":{"textDocument":{"uri":uri,"languageId":"wax","version":1,"text":src}}},
  >     {"jsonrpc":"2.0","id":2,"method":"textDocument/hover",
  >      "params":{"textDocument":td,"position":{"line":1,"character":10}}},
  >     {"jsonrpc":"2.0","id":3,"method":"textDocument/definition",
  >      "params":{"textDocument":td,"position":{"line":2,"character":2}}},
  >     {"jsonrpc":"2.0","id":4,"method":"textDocument/references",
  >      "params":{"textDocument":td,"position":{"line":2,"character":2},
  >                "context":{"includeDeclaration":True}}},
  >     {"jsonrpc":"2.0","id":5,"method":"textDocument/documentSymbol",
  >      "params":{"textDocument":td}},
  >     {"jsonrpc":"2.0","id":6,"method":"textDocument/formatting",
  >      "params":{"textDocument":td,"options":{"tabSize":2,"insertSpaces":True}}},
  >     {"jsonrpc":"2.0","id":7,"method":"shutdown"},
  >     {"jsonrpc":"2.0","method":"exit"},
  > ]
  > payload = b"".join(frame(m) for m in session)
  > p = subprocess.run(["wax","lsp"], input=payload,
  >                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
  > # split the framed replies
  > out, i, replies = p.stdout, 0, []
  > while i < len(out) and out[i:].startswith(b"Content-Length:"):
  >     n = int(out[out.index(b":",i)+1 : out.index(b"\r\n",i)])
  >     s = out.index(b"\r\n\r\n", i) + 4
  >     replies.append(json.loads(out[s:s+n])); i = s + n
  > by_id = {r["id"]: r["result"] for r in replies if "id" in r}
  > notifs = [r for r in replies if "method" in r]
  > def rng(r): return "(%d,%d)-(%d,%d)" % (
  >     r["start"]["line"], r["start"]["character"], r["end"]["line"], r["end"]["character"])
  > cap = by_id[1]["capabilities"]
  > print("initialize: name=%s hover=%s definition=%s references=%s rename=%s"
  >       % (by_id[1]["serverInfo"]["name"], cap["hoverProvider"],
  >          cap["definitionProvider"], cap["referencesProvider"],
  >          cap["renameProvider"]["prepareProvider"]))
  > print("encoding:", cap["positionEncoding"])
  > d = [n for n in notifs if n["method"] == "textDocument/publishDiagnostics"]
  > print("diagnostics:", len(d[0]["params"]["diagnostics"]) if d else "none")
  > print("hover:", by_id[2]["contents"]["value"].replace(chr(10), " | "))
  > print("definition:", ", ".join(rng(l["range"]) for l in by_id[3]))
  > print("references:", len(by_id[4]), "at", ", ".join(rng(l["range"]) for l in by_id[4]))
  > print("symbols:", ", ".join("%s/kind=%d/%s" % (s["name"], s["kind"], rng(s["range"]))
  >                             for s in by_id[5]))
  > e = by_id[6]
  > print("formatting: %d edit(s), reindented=%s"
  >       % (len(e), "    let c = a + b;" in e[0]["newText"]))
  > print("shutdown:", json.dumps(by_id[7]))
  > print("stderr:", p.stderr.decode().strip() or "(empty)")
  > PY
  initialize: name=wax-lsp hover=True definition=True references=True rename=True
  encoding: utf-16
  diagnostics: 0
  hover: ```wax | i32 | ```
  definition: (1,6)-(1,7)
  references: 2 at (1,6)-(1,7), (2,2)-(2,3)
  symbols: add/kind=12/(0,0)-(3,1)
  formatting: 1 edit(s), reindented=True
  shutdown: null
  stderr: (empty)

Position encoding is negotiated. A line with a multi-byte identifier (`é` is two
UTF-8 bytes but one UTF-16 unit) makes the two encodings disagree on column
offsets. When the client offers `utf-8` the server selects it, interprets the
incoming character offset as a byte column, and reports offsets back in bytes;
otherwise it uses `utf-16`. Drive the same hover under each and show the offsets
track the negotiated unit (Python computes each encoding's offset for the `x`
that sits after the `é`-bearing comment):

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > uri="file:///u.wax"; td={"uri":uri}
  > src="fn f(x: i32) -> i32 { /* é */ x + 0; }\n"
  > b=src.index("x + 0"); pre=src[:b]
  > off={"utf-16": len(pre.encode("utf-16-le"))//2, "utf-8": len(pre.encode("utf-8"))}
  > def hover(enc):
  >     caps={"general":{"positionEncodings":[enc,"utf-16"]}}
  >     S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":caps}},
  >        {"jsonrpc":"2.0","method":"initialized","params":{}},
  >        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"wax","version":1,"text":src}}},
  >        {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":td,"position":{"line":0,"character":off[enc]}}},
  >        {"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"}]
  >     p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  >     o,i,by=p.stdout,0,{}
  >     while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >         n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >         r=json.loads(o[s:s+n]); i=s+n
  >         if "id" in r: by[r["id"]]=r["result"]
  >     rg=by[2]["range"]
  >     return by[1]["capabilities"]["positionEncoding"], off[enc], rg["start"]["character"], rg["end"]["character"]
  > for enc in ("utf-16","utf-8"):
  >     e,c,s,t=hover(enc)
  >     print("offered %-6s -> negotiated=%s hover char=%d range=(%d,%d)" % (enc,e,c,s,t))
  > PY
  offered utf-16 -> negotiated=utf-16 hover char=30 range=(30,31)
  offered utf-8  -> negotiated=utf-8 hover char=31 range=(31,32)

A lint that flags removable or unreachable code (an unused local, import, field,
or label, or dead code) carries LSP's `DiagnosticTag.Unnecessary` (the value
`1`), so the editor fades the range as it does other dead code. Every lint also
carries a `codeDescription` linking its `-W` code to the hosted lint
documentation. A module with an unused local:

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > uri="file:///u.wax"
  > src="fn f() -> i32 {\n  let x = 1;\n  0;\n}\n"
  > S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >    {"jsonrpc":"2.0","method":"initialized","params":{}},
  >    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"wax","version":1,"text":src}}},
  >    {"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"}]
  > p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  > o,i=p.stdout,0
  > while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >     n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >     r=json.loads(o[s:s+n]); i=s+n
  >     if r.get("method")=="textDocument/publishDiagnostics":
  >         for d in r["params"]["diagnostics"]:
  >             print("%s: severity=%s tags=%s doc=%s" % (d.get("code"),
  >                   d["severity"], d.get("tags"),
  >                   (d.get("codeDescription") or {}).get("href")))
  > PY
  unused-local: severity=2 tags=[1] doc=https://ocsigen.org/wax/cli.html#warnings
