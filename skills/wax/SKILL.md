---
name: wax
description: >-
  Write, edit, review, or convert Wax, a Rust-like surface syntax for
  WebAssembly (.wax files) that compiles to WAT and WASM. Use whenever the task
  involves .wax source, or converting between Wax, WAT (.wat) and WASM (.wasm).
---

# Wax

Wax is a Rust-like surface syntax for WebAssembly. It converts bidirectionally
between Wax (source), WAT (WebAssembly text) and WASM (binary).

Wax has almost no presence in model training data, so do not rely on recall.
Two rules:

1. **Derive unfamiliar constructs from the analogues.** Wax maps closely onto
   Rust and onto WAT: reason as "it is like this Rust, and it lowers to this
   WAT." The full grammar, type system and mapping are in `reference.md`; read
   it before writing Wax you are unsure of.
2. **The compiler is the source of truth.** After writing or editing Wax,
   validate it and fix every reported error before returning it:

   ```
   wax check path/to/file.wax
   ```

   Exit 0 means valid; exit 128 means the input was rejected, with diagnostics
   on stderr. Iterate on the diagnostics until it is clean.

## Converting between formats

```
wax convert -i <from> -f <to> <input> [-o <output>]
```

Formats are `wax`, `wat`, `wasm`. For example, `wax convert -i wat -f wax
in.wat` decompiles WAT to Wax on stdout, and `wax convert -i wax -f wasm in.wax
-o out.wasm` compiles Wax to a binary. Use this to check how a construct lowers
(convert your Wax to `wat`) or to read existing WebAssembly as Wax. Binary
(`wasm`) output to a terminal is blocked, so pass `-o` for it.

## Reference

`reference.md` is the complete language reference: grammar, types, the CLI, and
worked examples. Load it when you need syntax detail. The examples double as a
Rust-and-WAT correspondence you can pattern-match against.

## Requirements

The commands above need the `wax` CLI on `PATH`. If it is missing, install the
Wax toolchain (a native release binary, or the npm package) and retry.
