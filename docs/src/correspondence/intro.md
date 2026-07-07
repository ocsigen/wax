# Introduction

This guide documents the correspondence between WebAssembly (Wasm) and Wax constructs. It is intended for developers who are familiar with Wasm and want to understand how Wax maps to it.

## High-level differences

Wax is an expression-oriented language, whereas Wasm is stack-oriented. However, Wax constructs map very closely to Wasm instructions, often one-to-one or with simple desugaring.

Key differences:
- **Expressions vs Stack**: Wax uses variables (`let`) and nested expressions instead of explicit stack manipulation (`local.get`/`set`, `drop`).
- **Control Flow**: Wax uses structured control flow (`if`, `loop`, `do`, `try`) that resembles high-level languages but maps directly to Wasm structured control instructions.
- **Types**: Wax types define a direct mapping to Wasm types, with a slightly more concise syntax.
- **Modules**: Wax modules group imports under an `import "module" { … }` block and mark exports with an `#[export]` attribute on the field itself, rather than using separate import/export definitions.
