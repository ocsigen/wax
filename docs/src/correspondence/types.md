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
| `(ref (exact <t>))` | `&!<t>` | Reference to *exactly* concrete type `<t>` |
| `(ref null (exact <t>))` | `&?!<t>` | Nullable reference to exactly `<t>` |

### Exact References

An **exact** reference (from the
[custom-descriptors proposal](https://github.com/WebAssembly/custom-descriptors))
points to values of exactly one concrete type, with no subtypes. Wax writes the
exactness marker `!` between the `&`/`&?` sigil and the type name, so it sits
alongside the nullability `?`:

```wax
let a: &!point = ...;   // (ref (exact $point))
let b: &?!point = ...;  // (ref null (exact $point))
```

Only a concrete (declared) type can be exact; `&!any` and other abstract heap
types are rejected. An exact reference is a subtype of the corresponding inexact
one (`&!point` flows where an `&point` is expected), but exactness is invariant
among distinct concrete types.

Because the `!` marker precedes the type name, it never clashes with the postfix
[non-null assertion](instructions.md#reference-instructions) `!`: `x as &!point`
is a cast to an exact reference, whereas `(x as &point)!` asserts the cast result
is non-null.

A concrete allocation — a struct or array [construction](instructions.md#aggregate-instructions)
— produces an exact reference (the fresh object has exactly the allocated type),
so a construction literal can be delivered where an `&!point` is required without
a cast. In ordinary (synthesis) position the plainer inexact type is kept, since
an exact result is always usable where an inexact one is expected.

A **function import** can be declared exact, so that referencing it yields an
exact reference. The `!` marks the type exact in the [function declaration](module_fields.md#functions):
`fn g: !ft;` for a named type, or `fn h!(x: i32) -> i64;` for an inline
signature. It maps to the WAT `(func (exact <type>))` import descriptor. (A
module-defined function is always exact, so the marker is only written on an
import.) A plainly imported function is *not* exact — its dynamic type may be a
subtype — so a reference to it must be cast to reach an exact type.

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
