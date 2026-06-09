# Types

Wax types map directly to WebAssembly types.

## Value Types

| Wasm | Wax | Notes |
|------|-----|-------|
| `i32` | `i32` | 32-bit integer |
| `i64` | `i64` | 64-bit integer |
| `f32` | `f32` | 32-bit float |
| `f64` | `f64` | 64-bit float |
| `v128` | `v128` | 128-bit vector |
| `(ref null <ht>)` | `&?<ht>` | Nullable reference to heap type `<ht>` |
| `(ref <ht>)` | `&<ht>` | Non-nullable reference to heap type `<ht>` |

## Storage Types

Storage types are used in fields of structs and arrays to define packed data.

| Wasm | Wax | Notes |
|------|-----|-------|
| `i8` | `i8` | 8-bit integer (packed) |
| `i16` | `i16` | 16-bit integer (packed) |

Any [value type](#value-types) is also a valid storage type; `i8` and `i16` are
the additional packed types available only in struct and array fields.


## Heap Types

| Wasm | Wax |
|------|-----|
| `func` | `func` |
| `extern` | `extern` |
| `any` | `any` |
| `eq` | `eq` |
| `struct` | `struct` |
| `array` | `array` |
| `i31` | `i31` |
| `exn` | `exn` |
| `cont` | `cont` |
| `noextern` | `noextern` |
| `nofunc` | `nofunc` |
| `noexn` | `noexn` |
| `nocont` | `nocont` |
| `none` | `none` |
| `<typeidx>` | `<identifier>` |

## Composite Types

### Recursive Types

Wax allows defining recursive reference types using `rec { ... }`.

```wax
rec {
    type tree = { value: i32, children: &forest };
    type forest = [&?tree];
}
```

### Structs
```wax
type point = { x: i32, y: i32 };
type mutable_point = { x: mut i32, y: mut i32 };
```
Maps to Wasm `(type $point (struct (field i32) (field i32)))`.

### Arrays
```wax
type bytes = [i8];
type mutable_bytes = [mut i8];
```
Maps to Wasm `(type $bytes (array i8))`.

### Functions
```wax
type binop = fn(_: i32, _: i32) -> i32;
```
Maps to Wasm `(type $binop (func (param i32 i32) (result i32)))`.
### Continuations
A continuation type (from the [stack-switching proposal](https://github.com/WebAssembly/stack-switching)) wraps a function type:
```wax
type ft = fn(i32) -> i32;
type k = cont ft;
```
Maps to Wasm `(type $k (cont $ft))`. See [Stack Switching Instructions](instructions.md#stack-switching-instructions) for the operations on continuations.

`cont` and `nocont` are reserved heap types (like `func`/`struct`), so the abstract continuation references `&cont`, `&?cont` and `&nocont` are available directly in addition to references to declared continuation types (`&k`, `&?k`). Because these names are reserved, a WebAssembly type literally named `$cont` is renamed (e.g. to `cont_2`) when decompiling to Wax.
### Supertypes and Finality

Types are final by default. To make a type open (extensible), use the `open` keyword.
To specify a supertype, use `: supertype` before the assignment.

```wax
type point = { x: i32, y: i32 };                  // final by default
type open_point = open { x: i32 };                // non-final: extensible
type sub_point : open_point = { x: i32, y: i32 }; // extends open_point
```
