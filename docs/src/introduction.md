# Introduction

Wax is a Rust-like syntax for WebAssembly that compiles to standard Wasm binary or text formats. It provides a more familiar programming experience while maintaining a direct correspondence to WebAssembly concepts.

## Why Wax?

WebAssembly Text format (WAT) uses S-expressions and stack-based operations, which can be verbose and unfamiliar to most programmers:

```wat
(func $add (param $x i32) (param $y i32) (result i32)
  local.get $x
  local.get $y
  i32.add)
```

Wax provides an expression-oriented syntax that feels more natural:

```wax
fn add(x: i32, y: i32) -> i32 {
    x + y;
}
```

Both compile to identical WebAssembly bytecode.

## Installation

**Requirements:** [Opam](https://opam.ocaml.org/) (2.1+) and OCaml 4.14+ (5.0+
to run the full test suite).

```sh
# Install dependencies
opam install . --deps-only

# Build
dune build

# Install globally
opam install .
```

## Quick Start

Create a file `hello.wax`:

```wax
#[export = "add"]
fn add(x: i32, y: i32) -> i32 {
    x + y;
}

#[export = "factorial"]
fn factorial(n: i32) -> i32 {
    if n <=s 1 => i32 {
        1;
    } else {
        n * factorial(n - 1);
    }
}
```

Compile to WebAssembly binary:

```sh
wax hello.wax -o hello.wasm
```

Or convert to WebAssembly text format to see the generated WAT:

```sh
wax hello.wax -f wat
```

Reformat files in place with the `format` command:

```sh
wax format -i hello.wax
```

## Supported Conversions

Wax supports all 9 combinations of input and output formats:

| Input | Output | Use Case |
|-------|--------|----------|
| `.wax` | `.wasm` | Compile to binary |
| `.wax` | `.wat` | Compile to text |
| `.wax` | `.wax` | Format / type-check |
| `.wat` | `.wasm` | Assemble to binary |
| `.wat` | `.wax` | Decompile to Wax |
| `.wat` | `.wat` | Format |
| `.wasm` | `.wat` | Disassemble |
| `.wasm` | `.wax` | Decompile to Wax |
| `.wasm` | `.wasm` | Round-trip |

## Type Checking

Compiling Wax to `.wat` or `.wasm` type-checks it automatically — type errors
are reported before any output is produced. For example, adding an `i32` and an
`f64`:

```
Error: This operator cannot be applied to operands of types i32 and f64.
 ──➤  hello.wax:3:5
1 │ #[export = "add"]
2 │ fn add(x: i32, y: f64) -> i32 {
3 │     x + y;
  ·     ^^^^^
4 │ }
```

The `-v`/`--validate` flag adds checks that are off by default: it validates a
same-format conversion (`.wax` → `.wax`) or a trusted `.wasm` input, and reports
unused locals.

## Next Steps

- [Language Guide](./language.md) — Variables, expressions, and control flow
- [Correspondence](./correspondence/intro.md) — How Wax maps to WebAssembly
- [CLI Reference](./cli.md) — Complete command-line options
