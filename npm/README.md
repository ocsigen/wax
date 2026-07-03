# wax

A compiler toolchain for [Wax](https://github.com/vouillon/wasm-syntax), a
Rust-like syntax for WebAssembly. It converts between three formats — Wax
(`.wax`), WebAssembly text (`.wat`), and WebAssembly binary (`.wasm`) — and can
type-check and format Wax.

This package is the `wax` command line tool, compiled from OCaml to WebAssembly
with [wasm_of_ocaml](https://github.com/ocsigen/js_of_ocaml). It is a single
self-contained package that runs on Node — the same package works on Linux,
macOS and Windows, with no per-platform native binaries.

## Requirements

Node.js with WebAssembly GC support — **Node 22 or newer**.

## Install

```sh
npm install -g wax
```

## Usage

```sh
wax --help                       # full CLI reference
wax input.wax -o output.wasm     # compile Wax to a Wasm binary
wax -i wat -f wax input.wat      # convert WAT to Wax (to stdout)
wax check input.wax              # type-check only
wax format -i input.wax          # reformat in place
```

`wax` reads from stdin when no input file is given, and writes to stdout when
`-o` is omitted (binary Wasm output to a terminal is refused; use `-o`).

## Notes

- The Unix primitives `fork`/`exec`/`pipe`/`dup2`/`waitpid` are not available in
  the WebAssembly build; the CLI does not use them.
- Built from source with `npm/build.sh` in the project repository.
