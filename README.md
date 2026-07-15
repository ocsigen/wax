<div align="center">
  <img src="assets/wax128.png" alt="Wax logo" width="120" height="120">
</div>

# Wax

[![CI](https://github.com/ocsigen/wax/actions/workflows/ci.yml/badge.svg)](https://github.com/ocsigen/wax/actions/workflows/ci.yml)
[![Nightly fuzzing](https://github.com/ocsigen/wax/actions/workflows/fuzz-nightly.yml/badge.svg)](https://github.com/ocsigen/wax/actions/workflows/fuzz-nightly.yml)
[![Documentation](https://img.shields.io/badge/docs-ocsigen.org%2Fwax-blue)](https://ocsigen.org/wax/)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

**Wax is a Rust-like syntax for WebAssembly.** Write Wasm (including WasmGC)
in a familiar, expression-oriented notation, and convert between Wax,
WebAssembly Text (WAT), and the binary format, in any direction.

Where the WebAssembly text format spells out a stack machine:

```wat
(func $add (param $x i32) (param $y i32) (result i32)
  local.get $x
  local.get $y
  i32.add)
```

Wax reads like a programming language:

```rust
fn add(x: i32, y: i32) -> i32 {
    x + y;
}
```

Both compile to identical bytecode, and the payoff grows with the program.
Struct types, nullable references, casts, and loops stay readable where the
equivalent WAT sprawls:

```rust
type list = { value: i32, next: &?list };

#[export = "sum"]
fn sum(l: &?list) -> i32 {
    let total: i32 = 0;
    while l is &list {
        total += l!.value;
        l = l!.next;
    }
    total;
}
```

<details>
<summary>The WAT this compiles to (<code>wax sum.wax -f wat</code>)</summary>

```wat
(type $list (struct (field $value i32) (field $next (ref null $list))))

(func $sum (export "sum") (param $l (ref null $list)) (result i32)
  (local $total i32)
  (local.set $total (i32.const 0))
  (loop $loop
    (if (ref.test (ref $list) (local.get $l))
      (then
        (local.set $total
          (i32.add (local.get $total)
            (struct.get $list $value (ref.as_non_null (local.get $l)))))
        (local.set $l
          (struct.get $list $next (ref.as_non_null (local.get $l))))
        (br $loop))))
  (local.get $total)
)
```

</details>

## Highlights

- **Full WebAssembly 3.0**: garbage collection, exception handling, tail
  calls, multiple and 64-bit memories, SIMD, plus stack switching, threads,
  wide arithmetic, and branch hints on by default. See
  [Feature Support](https://ocsigen.org/wax/features.html).
- **Every direction**: all 9 conversions between `wax`, `wat`, and `wasm`
  work, including decompiling an arbitrary `.wasm` binary into readable Wax.
- **A real type checker**: errors are caught before any output is produced,
  and reported with source context:

  ```
  Error: This operator cannot be applied to operands of types i32 and f64.
   ──➤  hello.wax:3:7
  1 │ #[export = "add"]
  2 │ fn add(x: i32, y: f64) -> i32 {
  3 │     x + y;
    ·       ^
  4 │ }
  ```

- **A toolchain, not just a compiler**: a formatter (`wax format`), a
  validator (`wax check`), configurable lints (`-W`), conditional compilation
  (`-D`), and source maps for debugging the generated Wasm in the browser.

## Quick start

```sh
wax input.wax -o output.wasm    # compile Wax to a Wasm binary (auto-detected from .wasm)
wax input.wat                   # convert WAT to Wax (to stdout)
wax program.wasm                # decompile a binary to Wax
wax check input.wax             # type-check only, no output
wax format -i input.wax         # reformat in place
```

The input format is detected from the file extension (override with `-i`); the
default output format is `wax` (override with `-f`). `wax` reads from `stdin`
when no input file is given and writes to `stdout` when `-o` is omitted.

See the [CLI reference](https://ocsigen.org/wax/cli.html) for the
complete set of options.

## Editor support

Editor integrations live under [`editors/`](editors/), all sharing the same
analysis:

- **[Visual Studio Code](editors/vscode/)** (on the
  [Marketplace](https://marketplace.visualstudio.com/items?itemName=wax-wasm.wax)):
  a full extension for `.wax` and `.wat`, with syntax highlighting, formatting,
  snippets, side-by-side compile/decompile previews, and the complete
  language-server feature set. It runs the toolchain compiled to WebAssembly
  in-process, so it works the same in desktop and web VS Code.
- **[Neovim](editors/nvim/)**, **[Helix](editors/helix/)**, and
  **[Emacs](editors/emacs/)**: the [`tree-sitter-wax`](tree-sitter-wax/) grammar
  for highlighting, plus the built-in `wax lsp` language server for diagnostics,
  hover, go to definition, find references, rename, completion, and signature
  help.

Any other editor with a Language Server Protocol client gets the same features
by launching `wax lsp`. See the [documentation](docs/src/editor.md) for setup
details.

## Installation

### Prebuilt binaries

Native `wax` executables for Linux, macOS (Apple silicon and Intel), and
Windows (with `SHA256SUMS`) are attached to the
[`edge` prerelease](https://github.com/ocsigen/wax/releases/tag/edge), which is
rebuilt on every push to `main`. Download the one for your platform, make it
executable, and put it on your `PATH`:

```sh
curl -LO https://github.com/ocsigen/wax/releases/download/edge/wax-linux-x86_64
chmod +x wax-linux-x86_64 && mv wax-linux-x86_64 /usr/local/bin/wax
```

### From source

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

## Documentation

Full documentation is available at
[ocsigen.org/wax/](https://ocsigen.org/wax/): a language guide,
the Wax↔WebAssembly correspondence, examples, and the CLI reference. You can
also build it locally with `mdbook build docs` (requires
[mdBook](https://rust-lang.github.io/mdBook/)).

## Correctness

Wax is built to be trusted with your binaries:

- It passes the **official WebAssembly spec test suite**.
- It is **fuzzed against the reference interpreter and
  [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools)**, which must
  agree with Wax on which modules are valid.
- Converting a module to Wax and back must reproduce its **exact behaviour**,
  verified by re-running the spec tests on round-tripped modules.

See [`fuzz/README.md`](fuzz/README.md) for how the harness works.

## Contributing

Contributions are welcome! See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the
submission process, the data-flow overview, and the checklists for changing
the AST or adding syntax.

Wax is licensed under [Apache-2.0](LICENSE).
