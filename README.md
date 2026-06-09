# Wax Compiler Toolchain

Wax offers a Rust-like syntax for WebAssembly, complete with tools to type-check, reformat, and convert code between Wax, Wasm binary, and Wasm text formats.

## Installation

**Requirements:** [Opam](https://opam.ocaml.org/) (2.1+) and OCaml 5.0+.

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
*   **Syntax Conversion:** Supports conversion between Wax, WebAssembly Text (WAT), and eventually WebAssembly Binary.

## Documentation
Full documentation is available at [vouillon.github.io/wax/](https://vouillon.github.io/wax/).
You can also build the documentation locally using `mdbook build docs`.

## CLI Interface


**Usage:** `wax [OPTION]… [INPUT]` (convert, the default command), `wax format [OPTION]… FILE…` (reformat files), or `wax check [OPTION]… FILE…` (validate files).

### Positional Arguments

*   `[INPUT]`: Source file to convert/format. Optional. If omitted, the tool reads from `stdin`.

### Options

*   `-f`, `--format`, `--output-format`: Output format (Default: Auto/`wasm`). Values: `wat`, `wasm`, `wax`.
*   `-i`, `--input-format`: Input format (Default: Auto/`wax`). Values: `wat`, `wasm`, `wax`.
*   `-o`, `--output`: Output file (Default: `stdout`).
*   `-v`, `--validate`: Perform validation (type checking for Wax, well-formedness for Wasm Text). Validation is disabled by default.
*   `-s`, `--strict-validate`: Perform strict reference validation (for Wasm Text). This overrides the default relaxed reference validation behavior.
*   `--color`: Color output: `always`, `never`, or `auto` (default). `auto` colors only if output is a TTY.
*   `--fold`: Fold instructions into nested S-expressions (for Wasm Text output).
*   `--unfold`: Unfold instructions into flat instruction lists (for Wasm Text output).

### `format` command

`wax format [OPTION]… FILE…` reformats files in their own format (detected from each extension).

*   `-i`, `--inplace`: Write the formatted output back to each file. Without it (and without `--check`), exactly one file is formatted to `stdout`.
*   `-c`, `--check`: Write nothing; list files that are not already formatted and exit non-zero if any are found.
*   `-f`, `--format`, `--input-format`: Treat all files as this format (`wat`, `wasm`, `wax`), overriding extension detection.
*   `-v`, `--validate`: Also type-check / well-formedness-check while formatting.
*   `--color`, `--fold`, `--unfold`: as above.

### `check` command

`wax check [OPTION]… FILE…` validates files (type-checking Wax, well-formedness Wasm) without producing output, exiting non-zero if any file fails.

*   `-f`, `--format`, `--input-format`: Treat all files as this format, overriding extension detection.
*   `-s`, `--strict-validate`: Strict reference validation (for Wasm Text).
*   `--color`: as above.

## Example

![Example](/assets/example.png)
