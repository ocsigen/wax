# Feature Support

Wax works across all three formats (Wax, WAT, Wasm) and targets recent
WebAssembly proposals, several of them **on by default**, that most toolchains
still gate. This page summarises what the toolchain accepts and produces.

## On by default

Wax fully supports the **WebAssembly 3.0** standard: garbage collection
(WasmGC), exception handling (`try_table`), tail calls, multiple memories,
64-bit memory (memory64), reference types, bulk memory, and SIMD (including
relaxed SIMD).

On top of that, it enables these further proposals by default:

| Proposal | In Wax |
|----------|--------|
| Stack switching (typed continuations) | `cont`, `suspend`, `resume`, … |
| Threads / atomics | shared memory, atomic loads/stores/RMW, `atomic::fence()` |
| Wide arithmetic | 128-bit integer ops (e.g. `i64::add128`) |
| Branch hinting | `#[likely]` / `#[unlikely]` |
| Custom page sizes | `pagesize` |
| [Extended name section](https://github.com/WebAssembly/extended-name-section) | `$`-identifiers for types, tables, memories, globals, data/element segments, fields, and labels survive the binary round-trip |

## Enabled with `-X`

Off by default; turn one on with `-X NAME` (see the [CLI reference](./cli.md)):

| Feature | What it adds |
|---------|--------------|
| `custom-descriptors` | exact reference types, descriptor structs, and the descriptor instructions (`descriptor` / `describes`) |
| `compact-import-section` | coalesces consecutive same-module imports into one group when emitting the binary. Groups written explicitly (in WAT, or already present in a binary) round-trip regardless of the flag; the flag only gates *deriving* groups from plain imports |

## Not supported

| Feature | Notes |
|---------|-------|
| Legacy `delegate` / `rethrow` | rejected on input. The rest of legacy exception handling (`try`/`catch`/`catch_all`) *is* supported: it has dedicated Wax syntax (`try { … } catch { … }`) and round-trips through the legacy binary opcodes |
| Component Model | |

### A deliberate relaxation

A tag may carry a **result type**: `tag yield(i32) -> i32`. The MVP requires
tags to have empty results; the stack-switching proposal lifts that (a suspended
tag resumes with a value), so Wax permits it on purpose. See
[Stack Switching](./language.md#stack-switching).
