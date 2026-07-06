Compiling to Wasm with --source-map-file emits a Source Map v3 alongside the
binary: valid JSON, base64-VLQ `mappings`, quoted `sources`, and a `file` field
naming the generated binary (not the map).

`f` refers to `g` only inside its body, so the compiler synthesizes an
`(elem declare func $g)`. That `ref.func` has no source location, so it is
recorded as an absent mapping (a 1-field segment) rather than inheriting the
previous instruction's location.

  $ wax decl.wax -f wasm -o decl.wasm --source-map-file decl.wasm.map
  $ cat decl.wasm.map
  {
    "version": 3,
    "file": "decl.wasm",
    "sourceRoot": "",
    "sources": ["decl.wax"],
    "sourcesContent": [],
    "names": [],
    "mappings": "CAGI,I"
  }

A source map relates a wasm binary's byte offsets to source positions, so it is
only meaningful for wasm output. Requesting one for text output is rejected
rather than silently ignored:

  $ wax decl.wax -f wat --source-map-file decl.map
  --source-map-file is only supported for wasm output
  [123]
