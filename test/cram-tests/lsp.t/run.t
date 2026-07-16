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

Diagnostics specialize to the conditional-compilation defines (the editor's
`wax.define`, mirroring `-D`), read from `initializationOptions` at startup and
from `workspace/didChangeConfiguration` live. A module whose `#[else]` branch has
a type error: with no defines it is reported (reachable when the condition is
false); setting `debug=true` selects the `#[if]` branch and drops it, leaving
only the taken branch's unused-global warning.

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > uri="file:///c.wax"
  > src="#[if(debug)]\n{\n  const x: i32 = 1;\n}\n#[else]\n{\n  const x: i32 = 1.5;\n}\n"
  > S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >    {"jsonrpc":"2.0","method":"initialized","params":{}},
  >    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"wax","version":1,"text":src}}},
  >    {"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{"wax":{"define":["debug=true"]}}}},
  >    {"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"}]
  > p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  > o,i,pubs=p.stdout,0,[]
  > while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >     n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >     r=json.loads(o[s:s+n]); i=s+n
  >     if r.get("method")=="textDocument/publishDiagnostics":
  >         pubs.append([("error" if d["severity"]==1 else "warning", d.get("code"))
  >                      for d in r["params"]["diagnostics"]])
  > print("on open (no defines): ", pubs[0])
  > print("after debug=true:     ", pubs[1])
  > PY
  on open (no defines):  [('error', None)]
  after debug=true:      [('warning', 'unused-field')]

A `#![feature = "…"]` inner attribute (Wax) or `(@feature "…")` annotation
(WAT) enables the named optional proposal for that buffer, with no editor
configuration: a descriptor-using module carrying it validates clean, while the
same module without it reports the gated construct.

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > wax_types="rec {\n  type obj = descriptor obj_desc { x: i32 };\n  type obj_desc = describes obj { };\n}\n"
  > wat_mod="(module (@feature \"custom-descriptors\")\n(rec\n  (type $obj (descriptor $obj_desc) (struct (field $x i32)))\n  (type $obj_desc (describes $obj) (struct))))\n"
  > bufs=[("declared.wax","wax","#![feature = \"custom-descriptors\"]\n"+wax_types),
  >       ("plain.wax","wax",wax_types),
  >       ("declared.wat","wat",wat_mod)]
  > S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >    {"jsonrpc":"2.0","method":"initialized","params":{}}]
  > for name,lang,src in bufs:
  >     S.append({"jsonrpc":"2.0","method":"textDocument/didOpen","params":
  >               {"textDocument":{"uri":"file:///"+name,"languageId":lang,"version":1,"text":src}}})
  > S+=[{"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"}]
  > p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  > o,i,pubs=p.stdout,0,{}
  > while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >     n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >     r=json.loads(o[s:s+n]); i=s+n
  >     if r.get("method")=="textDocument/publishDiagnostics":
  >         pubs[r["params"]["uri"].rsplit("/",1)[-1]]=[
  >             d["message"].split(",")[0] for d in r["params"]["diagnostics"]]
  > for name,_,_ in bufs: print("%s: %s" % (name, pubs[name] or "clean"))
  > PY
  declared.wax: clean
  plain.wax: ['This uses the custom-descriptors feature', 'This uses the custom-descriptors feature']
  declared.wat: clean

Diagnostics on `didChange` are debounced: a burst of edits coalesces into one
analysis (published once the client falls quiet, or on end of input), rather
than re-checking the whole buffer on every keystroke. Open a clean module, send
three rapid edits (the last introducing a type error), and close the stream: the
open publishes once, and the three changes collapse to a single publish.

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > uri="file:///d.wax"
  > def change(txt, v):
  >     return {"jsonrpc":"2.0","method":"textDocument/didChange",
  >             "params":{"textDocument":{"uri":uri,"version":v},
  >                       "contentChanges":[{"text":txt}]}}
  > S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >    {"jsonrpc":"2.0","method":"initialized","params":{}},
  >    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"wax","version":1,"text":"fn f() -> i32 { 0; }\n"}}},
  >    change("fn f() -> i32 { 1; }\n", 2),
  >    change("fn f() -> i32 { 2; }\n", 3),
  >    change("fn f() -> i32 { 1.5; }\n", 4)]
  > # No shutdown/exit: closing the stream makes the server flush pending on EOF.
  > p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),
  >                  stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
  > o,i,pubs=p.stdout,0,[]
  > while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >     n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >     r=json.loads(o[s:s+n]); i=s+n
  >     if r.get("method")=="textDocument/publishDiagnostics":
  >         pubs.append(["error" if d["severity"]==1 else "warning"
  >                      for d in r["params"]["diagnostics"]])
  > print("publishes:", pubs)
  > PY
  publishes: [[], ['error']]

Rename renames every occurrence of the symbol, but first checks the new name is
usable and does not change any name's resolution. Renaming the parameter `a`: to
a fresh name it succeeds (both occurrences rewritten); to `b` it is rejected,
since a second parameter `b` is already in scope and the rename would change
which one some name refers to; to a name that is not a valid identifier it is
also rejected. A rejected rename comes back as a JSON-RPC error (shown to the
user), not an edit.

  $ cat > ren.wax <<'WAX'
  > fn f(a: i32, b: i32) -> i32 { let t: i32 = a; t + b; }
  > WAX

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > uri="file:///ren.wax"; td={"uri":uri}; src=open("ren.wax").read()
  > def ren(id, newName):
  >     return {"jsonrpc":"2.0","id":id,"method":"textDocument/rename",
  >             "params":{"textDocument":td,"position":{"line":0,"character":5},"newName":newName}}
  > S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >    {"jsonrpc":"2.0","method":"initialized","params":{}},
  >    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"wax","version":1,"text":src}}},
  >    ren(2, "count"), ren(3, "b"), ren(4, "2bad"),
  >    {"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"}]
  > p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  > o,i,by=p.stdout,0,{}
  > while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >     n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >     r=json.loads(o[s:s+n]); i=s+n
  >     if "id" in r and r["id"] in (2,3,4): by[r["id"]]=r
  > def summ(r):
  >     if "error" in r: return "error: "+r["error"]["message"]
  >     edits=r["result"]["changes"][uri]
  >     return "%d edit(s) -> %s" % (len(edits), ",".join(e["newText"] for e in edits))
  > print("a->count:", summ(by[2]))
  > print("a->b:    ", summ(by[3]))
  > print("a->2bad: ", summ(by[4]))
  > PY
  a->count: 2 edit(s) -> count,count
  a->b:     error: Cannot rename to "b": that name is already in use, and the rename would change which definition one or more names refer to.
  a->2bad:  error: "2bad" is not a valid identifier.

A `.wat` document gets the same language features as Wax (over the WAT analysis:
the validator's recorded stack types for hover, the name-resolution table for
navigation and rename, a structural walk for folding). Open a small Wasm-text
module and drive one request of each kind:

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > uri="file:///m.wat"; td={"uri":uri}
  > src=("(module\n"
  >      "  (func $add (param $a i32) (param $b i32) (result i32)\n"
  >      "    (local.get $a) (local.get $b) (i32.add))\n"
  >      "  (func $main (result i32)\n"
  >      "    (call $add (i32.const 1) (i32.const 2))))\n")
  > S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >    {"jsonrpc":"2.0","method":"initialized","params":{}},
  >    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"wat","version":1,"text":src}}},
  >    {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":td,"position":{"line":2,"character":37}}},
  >    {"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":td,"position":{"line":4,"character":11}}},
  >    {"jsonrpc":"2.0","id":4,"method":"textDocument/references","params":{"textDocument":td,"position":{"line":1,"character":9},"context":{"includeDeclaration":True}}},
  >    {"jsonrpc":"2.0","id":5,"method":"textDocument/rename","params":{"textDocument":td,"position":{"line":4,"character":11},"newName":"sum"}},
  >    {"jsonrpc":"2.0","id":8,"method":"textDocument/rename","params":{"textDocument":td,"position":{"line":1,"character":9},"newName":"main"}},
  >    {"jsonrpc":"2.0","id":6,"method":"textDocument/foldingRange","params":{"textDocument":td}},
  >    {"jsonrpc":"2.0","id":7,"method":"textDocument/documentSymbol","params":{"textDocument":td}},
  >    {"jsonrpc":"2.0","id":10,"method":"textDocument/completion","params":{"textDocument":td,"position":{"line":4,"character":11}}},
  >    {"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"}]
  > p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  > o,i,by,pubs=p.stdout,0,{},[]
  > while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >     n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >     r=json.loads(o[s:s+n]); i=s+n
  >     if "id" in r: by[r["id"]]=r.get("result", r.get("error"))
  >     elif r.get("method")=="textDocument/publishDiagnostics": pubs.append(r["params"]["diagnostics"])
  > def rng(r): return "(%d,%d)-(%d,%d)"%(r["start"]["line"],r["start"]["character"],r["end"]["line"],r["end"]["character"])
  > print("diagnostics:", len(pubs[0]) if pubs else "none")
  > print("hover:", by[2]["contents"]["value"].replace(chr(10)," | "))
  > print("definition:", ", ".join(rng(l["range"]) for l in by[3]))
  > print("references:", ", ".join(rng(l["range"]) for l in by[4]))
  > ch=by[5]["changes"]
  > print("rename:", ", ".join("%s=%s"%(rng(e["range"]),e["newText"]) for lst in ch.values() for e in lst))
  > print("rename-clash:", by[8]["message"])
  > print("folding:", ", ".join("%d-%d"%(f["startLine"],f["endLine"]) for f in by[6]))
  > print("symbols:", ", ".join(s["name"] for s in by[7]))
  > print("completion:", ", ".join(c["label"] for c in by[10]))
  > print("stderr:", p.stderr.decode().strip() or "(empty)")
  > PY
  diagnostics: 1
  hover: ```wax | i32 | ```
  definition: (1,8)-(1,12)
  references: (1,8)-(1,12), (4,10)-(4,14)
  rename: (1,8)-(1,12)=$sum, (4,10)-(4,14)=$sum
  rename-clash: Cannot rename to "$main": that name is already in use, and the rename would change which definition one or more names refer to.
  folding: 1-2, 3-4
  symbols: $add, $main
  completion: $add, $main
  stderr: (empty)

The language is taken from the `languageId` the client declares at open, not the
URI's extension: a buffer opened as `wat` under a non-`.wat` URI is served as
Wasm text (its outline lists the function), while the same text opened as `wax`
is parsed as Wax (which cannot read it, so no outline). The extension is only a
fallback for a client that sends an unrecognized id.

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > wat="(module (func $f (result i32) (i32.const 1)))\n"
  > def doc(uri,lang): return {"uri":uri,"languageId":lang,"version":1,"text":wat}
  > S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >    {"jsonrpc":"2.0","method":"initialized","params":{}},
  >    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":doc("file:///scratch","wat")}},
  >    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":doc("file:///m2.wat","wax")}},
  >    {"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///scratch"}}},
  >    {"jsonrpc":"2.0","id":3,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///m2.wat"}}},
  >    {"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"}]
  > p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  > o,i,by=p.stdout,0,{}
  > while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >     n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >     r=json.loads(o[s:s+n]); i=s+n
  >     if "id" in r: by[r["id"]]=r.get("result")
  > print("wat-id, no extension:", ", ".join(s["name"] for s in by[2]) or "(empty)")
  > print("wax-id, .wat extension:", ", ".join(s["name"] for s in by[3]) or "(empty)")
  > PY
  wat-id, no extension: $f
  wax-id, .wat extension: (empty)

Inlay hints resolve a numeric index to the name it refers to, so numerically
indexed WAT reads without chasing each definition.

  $ python3 - <<'PY'
  > import subprocess, json
  > def frame(o):
  >     b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
  > uri="file:///m.wat"; td={"uri":uri}
  > src="(module\n  (func $helper (result i32) (i32.const 0))\n  (func (result i32) (call 0)))\n"
  > S=[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}},
  >    {"jsonrpc":"2.0","method":"initialized","params":{}},
  >    {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"wat","version":1,"text":src}}},
  >    {"jsonrpc":"2.0","id":2,"method":"textDocument/inlayHint","params":{"textDocument":td,"range":{"start":{"line":0,"character":0},"end":{"line":3,"character":0}}}},
  >    {"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"}]
  > p=subprocess.run(["wax","lsp"],input=b"".join(frame(m) for m in S),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  > o,i,by=p.stdout,0,{}
  > while i<len(o) and o[i:].startswith(b"Content-Length:"):
  >     n=int(o[o.index(b":",i)+1:o.index(b"\r\n",i)]); s=o.index(b"\r\n\r\n",i)+4
  >     r=json.loads(o[s:s+n]); i=s+n
  >     if "id" in r: by[r["id"]]=r.get("result")
  > print("inlays:", ", ".join("(%d,%d)%s"%(h["position"]["line"],h["position"]["character"],h["label"]) for h in by[2]) or "(none)")
  > PY
  inlays: (2,28) $helper
