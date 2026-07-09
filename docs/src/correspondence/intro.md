# Introduction

This guide documents the correspondence between WebAssembly (Wasm) and Wax constructs. It is intended for developers who are familiar with Wasm and want to understand how Wax maps to it.

## High-level differences

Wax is an expression-oriented language, whereas Wasm is stack-oriented. However, Wax constructs map very closely to Wasm instructions, often one-to-one or with simple desugaring.

Key differences:
- **Expressions vs Stack**: Wax uses variables (`let`) and nested expressions instead of explicit stack manipulation (`local.get`/`set`, `drop`).
- **Control Flow**: Wax uses structured control flow (`if`, `loop`, `do`, `try`) that resembles high-level languages but maps directly to Wasm structured control instructions.
- **Types**: Wax types define a direct mapping to Wasm types, with a slightly more concise syntax.
- **Modules**: Wax modules group imports under an `import "module" { … }` block and mark exports with an `#[export]` attribute on the field itself, rather than using separate import/export definitions.

## Extensions to WAT

Wax understands a few non-standard annotations in WAT. They reuse the standard `(@name …)` annotation syntax, but Wax gives them a meaning a stock WAT tool would not, so WAT that uses them round-trips only through Wax:

- **Literals**: `(@char "c")` and `(@string $t "…")` are character and string literals. `(@char …)` stands in for the `i32.const` of a code point; `(@string …)` for the `array.new_fixed` that builds an `i8` or `i16` array. They round-trip through WAT, but a Wasm binary keeps only the underlying instructions. See [Literals](instructions.md#literals). Use [`--desugar`](../cli.md#options) to expand them into plain wasm.
- **Conditional compilation**: `(@if <cond> (@then …) (@else …))` guards a module field by a condition that a downstream preprocessor resolves. It is the WAT counterpart of Wax's `#[if]`. See [Conditional Annotations](module_fields.md#conditional-annotations). Resolve conditions with [`-D`](../cli.md#options); an unresolved `(@if …)` makes `--desugar` fail.
