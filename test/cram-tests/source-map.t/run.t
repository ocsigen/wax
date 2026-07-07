Compiling to Wasm with --source-map-file emits a Source Map v3 alongside the
binary: valid JSON, base64-VLQ `mappings`, quoted `sources`, and a `file` field
naming the generated binary (not the map). A generated position is a byte offset
from the start of the whole binary, so mappings from different sections sort into
file order — here the `const` initializer (global section), then the synthesized
declare element, then `f`'s body (code section).

Each closing `end` opcode also gets a mapping, to the end of the construct it
terminates rather than inheriting the previous instruction's location: the
global's `end` maps to its `;`, and each function body's `end` to that function's
closing `}` (`g`'s on its own line, `f`'s on the last line).

`f` refers to `g` only inside its body, so the compiler synthesizes an
`(elem declare func $g)`. That `ref.func` has no source location, so it is
recorded as an absent mapping (a 1-field segment) that resets the mapping,
keeping the preceding `end`'s location from bleeding onto it.

  $ wax decl.wax -f wasm -o decl.wasm --source-map-file decl.wasm.map
  $ cat decl.wasm.map
  {
    "version": 3,
    "file": "decl.wasm",
    "sourceRoot": "",
    "sources": ["decl.wax"],
    "sourcesContent": [],
    "names": [],
    "mappings": "6BAAoB,EAAE,Q,QAEb,GAGL,EACH"
  }

A source map relates a wasm binary's byte offsets to source positions, so it is
only meaningful for wasm output. Requesting one for text output is rejected
rather than silently ignored:

  $ wax decl.wax -f wat --source-map-file decl.map
  --source-map-file is only supported for wasm output
  [123]
