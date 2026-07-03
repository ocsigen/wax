# Wax Compiler Toolchain

Wax offers a Rust-like syntax for WebAssembly, complete with tools to type-check, reformat, and convert code between Wax, Wasm binary, and Wasm text formats.

## Installation

**Requirements:** [Opam](https://opam.ocaml.org/) (2.1+) and OCaml 4.14+. The
toolchain builds on OCaml 4.14; running the full test suite requires 5.0+ (it
uses `Domain`).

```sh
# Install dependencies
opam install . --deps-only

# Build
dune build

# Run tests
dune runtest

# Install
opam install .
```

## Capabilities

*   **Formatting:** Ensures consistent code style.
*   **Type Checking:** Verifies the semantic correctness of Wax code.
*   **Syntax Conversion:** Converts between Wax, WebAssembly Text (WAT), and WebAssembly Binary (the default output) — in any direction.

## How it's tested

Beyond unit and cram tests, Wax runs the official WebAssembly spec test suite and
is guarded by a differential, round-trip fuzzing harness (see
[`fuzz/README.md`](fuzz/README.md)). It cross-checks validation against the
WebAssembly reference interpreter and
[`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) in both directions,
requires every module to survive a decompile-and-recompile round-trip, and
re-runs spec assertions through an execution oracle after the round-trip.
Generation (wasm-smith), AST/byte mutation, and deterministic lattice sweeps feed
the oracles.

## Documentation
Full documentation is available at [vouillon.github.io/wax/](https://vouillon.github.io/wax/).
You can also build it locally with `mdbook build docs` (requires
[mdBook](https://rust-lang.github.io/mdBook/)).

## CLI Interface

`wax` is a group of three commands: the default converts between formats,
`format` reformats files, and `check` validates them.

```sh
wax input.wax -o output.wasm      # compile Wax to a Wasm binary (the default output)
wax -i wat -f wax input.wat       # convert WAT to Wax (to stdout)
wax check input.wax               # type-check only, no output
wax format -i input.wax           # reformat in place
```

The input format is detected from the file extension (override with `-i`); the
default output format is `wasm` (override with `-f`). `wax` reads from `stdin`
when no input file is given and writes to `stdout` when `-o` is omitted.

See the [CLI reference](https://vouillon.github.io/wax/cli.html) for the
complete set of options — including `-D`/`-X`/`-W`, `--source-map-file`, the
validation flags, and the exit-status contract.

## Example

![Example](/assets/example.png)
