# Wax language reference

Wax is a Rust-like surface syntax for WebAssembly. It converts bidirectionally
between Wax (source), WAT (WebAssembly text) and WASM (binary).

This file is the whole language reference assembled into one document, for use
as context by an AI coding assistant. Two things to lean on when writing Wax:

  1. Wax maps closely onto WAT and onto Rust. When unsure of a construct,
     derive it from "it is like this Rust, and lowers to this WAT" — the
     Correspondence sections below give the mapping explicitly.
  2. The compiler is the source of truth. Check any Wax you produce with
     `wax check FILE.wax` (exit 0 = valid; 128 = rejected, with diagnostics on
     stderr) and iterate on the errors.

The sections below are the documentation pages concatenated in reading order.


<!-- docs/src/introduction.md -->

# Introduction

Wax is a Rust-like syntax for WebAssembly that compiles to standard Wasm binary or text formats. It provides a more familiar programming experience while maintaining a direct correspondence to WebAssembly concepts. It is validated against the official WebAssembly spec test suite and a differential, round-trip fuzzing harness, so conversions preserve meaning across all three formats. See [Feature Support](./features.md) for the proposals it covers.

## Why Wax?

WebAssembly Text format (WAT) uses S-expressions and stack-based operations, which can be verbose and unfamiliar to most programmers:

```wat,check
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

### npm

The easiest way to get `wax` is from npm; it ships a single cross-platform
WebAssembly build that runs on any Node 22+ (Linux, macOS, Windows):

```sh
npm install -g @wax-wasm/wax
```

### Prebuilt binaries

Native `wax` executables for Linux, macOS (Apple silicon and Intel), and
Windows (with `SHA256SUMS`) are attached to each
[release](https://github.com/ocsigen/wax/releases/latest). Download the one for
your platform, make it executable, and put it on your `PATH`:

```sh
curl -LO https://github.com/ocsigen/wax/releases/latest/download/wax-linux-x86_64
chmod +x wax-linux-x86_64 && mv wax-linux-x86_64 /usr/local/bin/wax
```

The [`edge` prerelease](https://github.com/ocsigen/wax/releases/tag/edge)
carries the same binaries built from the latest `main`, rebuilt on every push.

### From source

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

## Editor support

Wax works in Visual Studio Code through a dedicated [extension](https://marketplace.visualstudio.com/items?itemName=wax-wasm.wax), and in any editor with a Language Server Protocol client (Neovim, Emacs, Helix, and others) through the built-in [`wax lsp`](cli.md#language-server) server paired with the `tree-sitter-wax` grammar. Both give the same features: diagnostics, hover, go to definition, find references, rename, completion, signature help, formatting, and more. See [Editor Support](editor.md) for the details and per-editor setup.

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

Compiling Wax to `.wat` or `.wasm` type-checks it automatically; type errors
are reported before any output is produced. For example, adding an `i32` and an
`f64`:

```
Error: This operator cannot be applied to operands of types i32 and f64.
 ──➤  hello.wax:3:7
1 │ #[export = "add"]
2 │ fn add(x: i32, y: f64) -> i32 {
3 │     x + y;
  ·       ^
4 │ }
```

The `-v`/`--validate` flag adds checks that are off by default: it validates a
same-format conversion (`.wax` → `.wax`) or a trusted `.wasm` input, and reports
unused locals.

## Next Steps

- [Language Guide](./language.md): Variables, expressions, and control flow
- [Correspondence](./correspondence/intro.md): How Wax maps to WebAssembly
- [CLI Reference](./cli.md): Complete command-line options


<!-- docs/src/features.md -->

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
| [WAT numeric values](https://github.com/WebAssembly/wat-numeric-values) | typed numeric runs in [data segments](./language.md#data-segments) (`data d = [i16: -1, 2] ++ [f32: 0.5, nan] ++ [v128: i32x4(1,2,3,4)];`); runs survive the wax↔wat round-trip |

## Enabled with `-X`

Off by default; turn one on with `-X NAME` (see the [CLI reference](./cli.md)):

| Feature | What it adds |
|---------|--------------|
| `custom-descriptors` | exact reference types, descriptor structs, and the descriptor instructions (`descriptor` / `describes`) |
| `compact-import-section` | writes same-module imports under one module name in the binary import section. From a text input it lowers a `import "m" { … }` block / `(import "m" (item …) …)` group to a compact entry (a shared-type group when the items' types match, else one type per item; a one-item block flattens; separate imports are never merged). From a binary input it coalesces runs of consecutive same-module plain imports. Groups written explicitly (in WAT, or already present in a binary) round-trip regardless of the flag |

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


<!-- docs/src/language.md -->

# Language Guide

This guide covers Wax syntax and semantics. For the detailed mapping to WebAssembly instructions, see [Correspondence](./correspondence/intro.md).

## Module Name

A whole `.wax` file is a module. To give the module a name, place a
`#![module = "..."]` inner attribute at the top of the file:

```wax,check
#![module = "my_module"]

fn f() -> i32 {
    1;
}
```

Unlike the `#[...]` outer attributes that decorate a following field (such as
`#[export = "name"]`), `#![...]` is an *inner* attribute: it applies to the
enclosing module. A module may carry at most one name.

(This maps to the WebAssembly module name stored in the `name` custom section,
the `$name` in a WAT `(module $name …)`; see
[Module Fields](./correspondence/module_fields.md#module-name).)

## Features

A module can declare the optional proposals it uses (the `-X`/`--feature` set,
such as `custom-descriptors` or `compact-import-section`) with a
`#![feature = "..."]` inner attribute at the top of the file, one feature per
attribute:

```wax,check
#![feature = "custom-descriptors"]

rec {
    type obj = descriptor obj_desc { x: i32 };
    type obj_desc = describes obj { };
}
```

The file is then self-describing: it compiles, validates, and round-trips
without every consumer passing `-X`, and the editor needs no configuration.
The value is a feature name exactly as `-X` spells it; an unknown name is an
error listing the known features. Repeating an attribute is allowed
(declaring a feature is idempotent).

The attribute states a fact ("this module uses X"), while an explicit
`-X x=off` states a policy; neither silently overrides the other:

- The file declares X and the command line is silent: X is enabled.
- The file is silent and the command line passes `-X x`: X is enabled.
- Both declare and enable X: X is enabled.
- The file declares X but the command line passes `-X x=off`: this is an
  error, reported once at the attribute.

(This maps to a module-level `(@feature "...")` annotation in WAT, and to a
`+name` entry of the conventional `target_features` custom section in the
binary; see
[Module Fields](./correspondence/module_fields.md#feature-declarations).
Decompiling a binary restores the attribute from that section and from the
gated encodings the module actually uses, so even a binary from a producer
that wrote no section decompiles to a self-describing module.)

## Comments

Wax supports C-style comments:

```wax,check
// Single-line comment

/* Multi-line
   comment */
```

## Trailing Commas

A trailing comma is allowed after the last element of any comma-separated
list: function parameters, call arguments, struct fields, result types, and
so on:

```wax,check
type point = { x: i32, y: i32, };

fn add(a: i32, b: i32,) -> i32 {
    a + b;
}
```

## Literals

### Integers

```wax
42          // Decimal
0x2A        // Hexadecimal
```

A numeric literal is **flexible**: it has no fixed type of its own but takes a
concrete one from its context: a type annotation, the operation it feeds, or a
function's result type.

```wax,check
let x: i64 = 42;        // takes i64 from the annotation
```

Which concrete types a literal can take depends on its magnitude:

| Literal | Can become | Defaults to |
|---------|-----------|-------------|
| fits in 32 bits (≤ `0xFFFF_FFFF`) | `i32`, `i64`, `f32`, `f64` | `i32` |
| larger, fits in 64 bits | `i64`, `f32`, `f64` (never `i32`) | `i64` |
| larger than 64 bits | `f32`, `f64` only | `f64` |
| a floating-point literal | `f32`, `f64` | `f64` |

The *defaults* apply only when nothing constrains the literal:

```wax,check
let a = 42;             // unconstrained -> i32
let b = 5_000_000_000;  // too big for i32 -> i64
let c = 3.14;           // float literal -> f64
```

Wax performs **no implicit conversions** between numeric types. A numeric
expression must be coherent: an operator's operands must share one type, so
mixing an `i32` with an `i64`, or an integer with a float, does not type-check.
A flexible literal is never converted; it simply takes the type that keeps its
expression coherent. An operation that accepts only integers (a bitwise op, a
shift, `ctz`, …) holds the flexible literals feeding it to the integer family,
so they can only be `i32` or `i64`, never a float.

Changing a value's type takes an explicit [`as` cast](#type-conversions), which
emits the conversion: an out-of-range constant `as i32` wraps to its low 32
bits, and an integer `as f64` converts.

### Floating Point

```wax
3.14        // Decimal
1.0e10      // Scientific notation
0x1.5p10    // Hexadecimal float
inf         // Infinity
nan         // Not a number
```

A floating-point literal is `f32` or `f64`, defaulting to `f64` when
unconstrained (see the table above).

### Characters

A character literal is a single character in single quotes. It evaluates to that
character's Unicode code point as an `i32`: it is simply a readable spelling of
an `i32.const`:

```wax
'A';            // 65
'\n';           // 10
'\x41';         // 65, a byte written as two hex digits
'\u{1F600}';    // 128512, a Unicode code point
```

The recognised escapes are `\t`, `\n`, `\r`, `\'`, `\"`, `\\`, `\xNN` (exactly
two hex digits, one byte), and `\u{...}` (a Unicode code point in hex). For
text, see [Strings](#strings).

A character literal round-trips through WAT, where it is written with a
`(@char …)` annotation. A Wasm binary keeps only the underlying `i32.const`,
though, so decompiling from Wasm yields the plain integer code point.

## Variables

### Local Variables

Declare local variables with `let`. Each variable gets a type, either from an
explicit annotation or from an initializer:

```wax,check
fn example() -> i32 {
    let x: i32;        // annotated, no initializer
    let y = 20;        // type inferred from the initializer (i32)
    x = 10;
    x + y;
}
```

Unlike Rust, a local is freely mutable: there is no `let mut`, and no
immutable-local form. (`mut` exists in Wax, but it marks
[struct fields](#structs) and array element types, not bindings; the
immutable module-level form is [`const`](#global-variables).)

A local declared without an initializer starts at its type's zero value (`0`,
`0.0`, or `null`). When the type is omitted, it is taken from the initializer;
an otherwise-unconstrained integer literal then defaults to `i32` and a float to
`f64`. An annotation and an initializer can be combined, and must agree:

```wax,check
let count: i64 = 0;
```

A `let` can bind several names at once from an initializer that produces
multiple values, a call to a [multi-result function](#functions),
for instance. The names are written as a parenthesised list and each takes the
corresponding value, left to right. As with a single binding, each name may be
annotated or left to be inferred, and `_` discards its value:

```wax
let (q, r) = divmod(17, 5);     // q and r inferred from the results
let (n: i64, _) = stats();      // n annotated, the second result dropped
```

### Assignment

Use `=` for assignment (like `local.set`):

```wax
x = 42;
```

Use `:=` for assignment that also returns the value (like `local.tee`):

```wax
y = (x := 42) + 1;  // x is set to 42, y is set to 43
```

`:=` works on local variables only: WebAssembly has no `global.tee`, so applying
it to a global is an error.

A compound assignment combines a binary operator with `=`: `x op= e` is
shorthand for `x = x op e`, where the left-hand side is a local or global
variable.

```wax
counter += 1;       // counter = counter + 1
mask &= 0xff;        // mask = mask & 0xff
total /s= n;         // total = total /s n
```

Every value-producing arithmetic and bitwise operator has a compound form:
`+=`, `-=`, `*=`, `/=`, `/s=`, `/u=`, `%s=`, `%u=`, `&=`, `|=`, `^=`, `<<=`,
`>>s=`, and `>>u=`. As for the corresponding binary operators, the signed and
unsigned variants apply to integers, while the sign-agnostic `/=` is float
division. Comparisons have no compound form.

### Discarding a value

Assigning to `_` evaluates an expression and throws its result away, the
equivalent of WebAssembly's `drop`. Nothing is bound, so no name comes into
scope:

```wax
_ = f();            // call f for its side effects, ignore its result
```

An optional type annotation, `_: t = e`, pins the type of the discarded value.
This is hardly ever needed, since the value is thrown away anyway:

```wax
_: i64 = 1 << 40;   // discard the result, but keep it i64
```

### Global Variables

Globals are declared at module level. `const` is immutable; `let` is mutable:

```wax,check
const PI: f64 = 3.14159;        // immutable global
let counter: i32 = 0;           // mutable global
```

As with locals, an initialized global may omit its type and take it from the
initializer (an unconstrained integer literal defaults to `i32`):

```wax,check
const answer = 42;              // i32
```

A global's initializer must be a constant expression (a literal, another
global, or a simple reference-building expression).

### Names and Scope

Functions, globals, memories, and tables share one module-level namespace: a
name must be distinct across all four: you cannot, say, declare both a memory
and a global named `buf`. Types, tags, and data/element segments each have their
own namespace, so those names may overlap with the above and with one another.

A local variable is scoped to its function and takes precedence over module-level
names. A bare name resolves to a local before a global or function, and the
name-based module forms (`mem.load(..)`, `tab[i]`, `seg.drop()`) likewise defer
to a same-named local. So a local that reuses a memory, table, or segment name
shadows it; rename the local if you still need to reach the module entity.

## Expressions

Wax is a readable layer over WebAssembly, and it keeps WebAssembly's execution
model: the **operand stack**. A function or block body is a sequence of
statements, each ended with `;`. Evaluating a statement may push values onto the
stack and pop values off it, and whatever remains on the stack when the body
ends is its result, which must match the declared result type. A
value-returning function therefore ends with a statement that leaves that value:

```wax,check
fn double(x: i32) -> i32 {
    x * 2;
}
```

Most expressions produce a value. This same stack model underlies
[blocks](#blocks), [holes](#holes), and functions or blocks with more than one
result.

### Arithmetic

```wax
x + y       // Add
x - y       // Subtract
x * y       // Multiply
x / y       // Divide (float)
x /s y      // Divide signed (integer)
x /u y      // Divide unsigned (integer)
x %s y      // Remainder signed
x %u y      // Remainder unsigned
```

### Bitwise

```wax
x & y       // And
x | y       // Or
x ^ y       // Xor
x << y      // Shift left
x >>s y     // Shift right signed
x >>u y     // Shift right unsigned
```

### Comparison

```wax
x == y      // Equal
x != y      // Not equal
x < y       // Less than (float)
x <s y      // Less than signed (integer)
x <u y      // Less than unsigned (integer)
x <= y      // Less or equal (float)
x <=s y     // Less or equal signed
x <=u y     // Less or equal unsigned
// Similarly: >, >=, >s, >u, >=s, >=u
```

On reference operands (any subtype of `&eq`), `==` and `!=` are reference
identity, not a numeric comparison.

### Unary Operations

```wax
-x          // Negate
+x          // Positive (no-op for integers)
!x          // Logical not / is_null for references
```

Unlike Rust, `!` on an integer is *logical* not, not bitwise complement: it
yields `1` for `0` and `0` for any non-zero value (Wasm's `eqz`), so `!5` is
`0`, not `-6`. For a bitwise complement, write `x ^ -1`.

### Operator Precedence

Operators are listed below from highest precedence (binds tightest) to lowest.
The ordering follows **Rust's** for every operator the two share (Wax adds
`? :`, which Rust lacks, just above assignment; it has no short-circuit `&&`/`||`:
`&`/`|` are bitwise). Two mixes are worth committing to memory:

- `&`, `^`, `|` bind **tighter** than the comparison operators, so `a & b == c`
  parses as `(a & b) == c`. Rust agrees; C is the opposite: there it means
  `a & (b == c)`.
- The shifts bind **looser** than `+`/`-`, so `1 << nbits - 1` parses as
  `1 << (nbits - 1)`, not `(1 << nbits) - 1`. (Same in Rust and C.)

| Precedence | Operators | Associativity |
|------------|-----------|---------------|
| highest | `.field` &nbsp; `f(…)` &nbsp; `[…]` (field, call, index) | left |
|  | `-x` &nbsp; `+x` &nbsp; `!x` (unary) | n/a |
|  | `as` &nbsp; `is` (cast, test) | left |
|  | `*` &nbsp; `/` &nbsp; `/s` &nbsp; `/u` &nbsp; `%s` &nbsp; `%u` | left |
|  | `+` &nbsp; `-` | left |
|  | `<<` &nbsp; `>>s` &nbsp; `>>u` | left |
|  | `&` | left |
|  | `^` | left |
|  | <code>&#124;</code> | left |
|  | `==` &nbsp; `!=` &nbsp; `<` &nbsp; `>` &nbsp; `<=` &nbsp; `>=` (and `s`/`u` forms) | none |
|  | `? :` | right |
| lowest | `=` &nbsp; `:=` &nbsp; `+=` … (assignment) | right |

Because the two cross-class mixes above are easy to misread, the
[`precedence` lint](cli.md) (in the `correctness` group, on by default) flags a
shift mixed with arithmetic, or a comparison mixed with a bitwise operator, when
it is written without disambiguating parentheses.

### Method-Style Operations

Some operations use method syntax. These are calls, so they take parentheses
even when they have no argument:

```wax
x.abs()       // Absolute value
x.sqrt()      // Square root
x.floor()     // Floor
x.ceil()      // Ceiling
x.trunc()     // Truncate
x.nearest()   // Round to nearest
x.clz()       // Count leading zeros
x.ctz()       // Count trailing zeros
x.popcnt()    // Population count
x.extend8_s()   // Sign-extend the low 8 bits
x.extend16_s()  // Sign-extend the low 16 bits
```

Two-argument operations pass the second operand as the argument:

```wax
x.min(y)
x.max(y)
x.copysign(y)
x.rotl(y)      // Rotate left
x.rotr(y)      // Rotate right
```

### Qualified Intrinsics

Most built-in operations are written as methods on a receiver (`x.clz()`,
`a.add_i32x4(b)` above). The few that have no natural receiver are written
instead as a **qualified path**, `type::member(args)`, a built-in free
function namespaced by the WebAssembly type it belongs to. These names are
built in, not user functions, and because the `::` form is distinct from an
ordinary name it can never clash with your own functions, globals, or locals.

Two families use this syntax today.

**`v128::`: SIMD free functions.** The vector constants (one argument per
lane) and `bitselect`, which have no receiver:

```wax
v128::i32x4(1, 2, 3, 4)         // a v128 constant (also a constant expression)
v128::f32x4(1.5, 2.5, 3.5, 4.5)
v128::bitselect(a, b, mask)           // per-bit select
```

**`i64::`: wide arithmetic.** 128-bit integer operations, taking and returning
their operands as `(low, high)` pairs of `i64`, so each returns two results
(bind them with a multi-value `let`):

```wax
i64::add128(a_lo, a_hi, b_lo, b_hi)   // 128-bit add, returns (lo, hi)
i64::sub128(a_lo, a_hi, b_lo, b_hi)   // 128-bit subtract
i64::mul_wide_s(a, b)                 // signed 64×64 → 128-bit product
i64::mul_wide_u(a, b)                 // unsigned 64×64 → 128-bit product
```

### Type Conversions

Use `as` for type conversions:

```wax
x as i32        // Wrap i64 to i32
x as i64_s      // Sign-extend i32 to i64
x as i64_u      // Zero-extend i32 to i64
x as f32        // Demote f64 to f32
x as f64        // Promote f32 to f64
x as i32_s      // Truncate float to signed int
x as f32_s      // Convert signed int to float
x.to_bits()     // Reinterpret float as int
x.from_bits()   // Reinterpret int as float
```

### Conditional Expression

```wax
cond ? val_true : val_false
```

This maps directly to Wasm's `select` instruction.

> **⚠ Warning: both branches are always evaluated.** Unlike the `?:` (or
> `if`/`else` expression) of most languages, this operator is *not* lazy: it
> compiles to a `select`, which computes *both* `val_true` and `val_false`
> before choosing between them. So `cond ? 1 /s x : 0` still divides by `x`
> even when `cond` is false (trapping if `x` is `0`), and `cond ? f() : g()`
> calls *both* `f` and `g`. When a branch may trap or has a side effect, use an
> [`if` expression](#if-expressions) instead: it evaluates only the chosen
> branch. The
> [`eager-select` lint](cli.md) (in the `correctness` group, on by default)
> flags a trapping or effectful operation in a `?:` branch.

## Control Flow

Statements are terminated by `;`, including the final one that produces the
block's or function's value. Unlike Rust, this trailing `;` is required and does
not discard that value: the value stays on the stack and becomes the result.
The block-shaped statements below
(`do`, `if`, `while`, `loop`, `dispatch`, `match`, and `try`) are the
exception: their closing `}` ends the statement, so no `;` is needed. A bare
`;` is an empty statement (it does nothing), so a redundant one is harmless
anywhere and dropped on formatting, most usefully after a block, where the
reflex of ending every line with `;` would otherwise be an error. The same
holds outside function bodies: a stray `;` is an empty element wherever items
are listed: among module fields, the declarations of an `import` block, and
the arms of a `dispatch`, `match`, or `catch`.

### Blocks

A block groups a sequence of statements, written with `do`.

```wax
do {
    let x: i32;
    x = compute();
    use(x);
}
```

By default a block is **void**: it produces no value, so, like a function with
no result type, its body must leave the operand stack empty.

To make a block produce a value, give it a result type after `do`. The body
must leave a value of that type on the stack, and that becomes the block's
value:

```wax
answer = do i32 {
    42;
};
```

This is a stack discipline, not a "last expression" rule: the body must leave
*exactly* the values the block's type describes: no more, no less. A void
block that leaves a value, or a `do i32` block that leaves two, is an error.

The result type may be **omitted** and inferred: from the value the body leaves
(including a value branched to the block's own label), or from the surrounding
context such as a function's result type, a typed binding, or a call argument.
It is needed only where neither determines it, for instance when two branches
produce values with no common supertype. So the block above can drop its `i32`:

```wax
answer = do {
    42;
};
```

`loop`, `try`, and `try_table` infer their result type the same way. Converting
WebAssembly to Wax drops the annotation wherever it is redundant, and re-reading
that Wax recovers the type by the same inference.

A block type may also take parameters off the enclosing stack, using the full
`(params) -> results` form:

```wax
do (i32) -> i32 {
    // the i32 operand below the block is available here
}
```

Parameters only work when the block stands on its own as a statement, where
those values come from the operand stack. A block used *inside* an expression
has no enclosing stack to draw from, so it cannot take parameters. To combine a
parameterized block's result with other operands, keep the block at statement
level and pick up its result with a [hole](#holes):

```wax
x;                        // leaves an i32 on the stack
do (i32) -> i32 { … }     // a statement: consumes that i32, leaves an i32
_ + 1;                    // the hole plugs in the block's result
```

Blocks can be labelled and used as branch targets; see
[Labels and Branches](#labels-and-branches).

### If Expressions

`if` tests a condition (any `i32`, where non-zero means true) and runs the
matching branch. Like a block it is **void** by default (the branches leave no
value), and the `else` is optional:

```wax
if condition {
    then_branch;
}
```

To make `if` produce a value, give it a result type with `=> <type>`. Both
branches must then leave a value of that type, so the `else` becomes required:

```wax
if condition => i32 {
    1;
} else {
    0;
}
```

Like a block's result type, the `=> <type>` may be **omitted** and inferred:
from the branches (here both produce `i32`) or from the surrounding context. The
`else` stays required, since a value-producing `if` needs both branches:

```wax
x = if condition {
    1;
} else {
    0;
};
```

### Loops

A `loop` runs its body once and then falls through to whatever follows: it does
*not* repeat on its own. What makes it a loop is its label: branching to a
loop's label jumps back to the **start** of its body. So a loop iterates by
branching to itself, and stops once control reaches the end of the body without
branching back.

```wax
'next: loop {
    total = total + i;
    i = i + 1;
    br_if 'next i <s n;   // jump back to the start while i < n
}
```

This is the opposite of a `do` block, whose label branches *past* the block (see
[Labels and Branches](#labels-and-branches)). To leave a loop early, branch to
an enclosing block's label.

Loops nest, and a branch may target any enclosing label:

```wax
'outer: loop {
    'inner: loop {
        br 'outer;   // jump back to the start of the outer loop
    }
}
```

### While Loops

A `while` is readable sugar over the `loop`-and-back-branch idiom above; it
tests *before* each iteration:

```wax
while i <s n {
    total = total + i;
    i = i + 1;
}
```

which is exactly:

```wax
'next: loop {
    if i <s n {
        total = total + i;
        i = i + 1;
        br 'next;
    }
}
```

It is void, and the test must be an `i32`. It may carry a label
(`'l: while …`), which names the loop, so a `br 'l` from inside the body is a
*continue*: it jumps back to re-test. Decompiling recovers a `while` from this
shape, so a loop written this way survives a round trip through WAT or Wasm.

A `while` may carry a *continue-expression* after the condition,
`while cond : (step) { … }`, a statement run at the end of every iteration,
including on a `continue`. It keeps the loop's step next to its header instead of
at the bottom of the body, and, unlike a step written as the last statement,
it still runs when the body branches to the loop label:

```wax
'l: while i <s n : (i += 1) {
    if skip(i) { br 'l; }   // continue: runs `i += 1`, then re-tests
    total += i;
}
```

The step must be parenthesised (a bare statement would be ambiguous with the
loop body). Without a `continue` this is equivalent to writing the step as the
last statement of the body, and decompiling recovers it: a loop whose last
statement updates a variable its condition reads (the induction variable) is
rendered as `while … : (step) { … }`, so index-and-stride loops read like `for`
loops.

A *trailing*-test loop, where the body always runs at least once, has no
leading-`while` form. Write it directly as a `loop` with a back-`br_if`:

```wax
'next: loop {
    total = total - 1;
    br_if 'next total >s 0;
}
```

### Labels and Branches

Labels start with `'` and prefix a block, loop, `if`, or `try`. A branch targets
a label; **where** it lands depends on the labelled construct: branching to a
block, `if`, or `try` jumps *past* it (an exit), while branching to a `loop`
jumps to its *start* (an iteration, see [Loops](#loops)).

```wax
'done: do {
    if condition {
        br 'done;   // jump past the block (exits it)
    }
    // ...
}
```

Branch instructions:

```wax
br 'label;                          // unconditional branch
br_if 'label cond;                  // branch if cond (an i32) is non-zero
br_table ['a, 'b, else 'default] i;   // branch to the i-th label, else 'default
```

The labels in a `br_table` are separated by commas, and the mandatory final
`else` gives the fallback for an out-of-range index. A branch also carries any values its target
expects: a `do i32` target receives an `i32`, and so on.

Four more branch instructions test a reference and branch on the result, passing
the refined reference to the target. They appear mainly in Wax decompiled from
WebAssembly; hand-written code usually reaches for [`match`](#match), a
[null check](#null-check), or a [cast or test](#type-testing-and-casting)
instead.

```wax
br_on_null 'l val;          // branch if val is null; else continue with val non-null
br_on_non_null 'l val;      // branch (passing val) if val is non-null; else continue
br_on_cast 'l &t val;       // branch (passing val as &t) if val is a &t; else continue
br_on_cast_fail 'l &t val;  // branch if val is not a &t; else continue with val as &t
```

### Branch Hints

A conditional branch can be annotated `#[likely]` or `#[unlikely]` to tell the
engine which way it usually goes (the
[branch-hinting proposal](https://github.com/WebAssembly/branch-hinting)). The
attribute prefixes the branch:

```wax
#[likely] if cond {
    // the common case
} else {
    // the rare case
}

'next: loop {
    #[unlikely] br_if 'next done;   // rarely taken
}
```

Any conditional branch accepts a hint: `if`, `br_if`, `br_on_null`,
`br_on_non_null`, `br_on_cast`, and `br_on_cast_fail`. The hint is purely
advisory (it does not change behaviour) and is preserved across every conversion
to and from WebAssembly, so no compiler flag is needed. See
[Instructions → Branch Hints](correspondence/instructions.md#branch-hints) for
the WebAssembly encoding.

### Dispatch

A `dispatch` is a multi-way branch, the readable form of a `br_table` jump
table. A bracket maps an index to a case label (with an `else` default for an
out-of-range index), and each arm gives that case's body:

```wax,check
fn classify(x: i32) -> i32 {
    dispatch x ['zero, 'one, 'two, else 'big] {
        'big:  { return 99; }
        'two:  { return 30; }
        'one:  { return 20; }
        'zero: { return 10; }
    }
}
```

The bracket is exactly the underlying `br_table`: index `0` jumps to the label
named first, `1` to the second, and so on, and an out-of-range index jumps to
the `else` label. A label may be listed more than once (several indices sharing
a case), and every listed label (and `else`) must name an arm. The index must be
an `i32`, and the labels are 0-ary branch targets. Case (arm) labels must be
distinct.

`dispatch` lowers to one nested block per case, with the `br_table` in the
innermost block and each case body just after its block. As in a C `switch`,
cases **fall through**: reaching a case runs its body and then falls into the
*next* arm listed, unless it branches away first. So the arms are written in
fall-through order, which is the reverse of the bracket's index order: the
last arm is the one index `0` reaches. The example above gives each case its
own result via `return`; to break out instead, branch to an enclosing label:

```wax
let r: i32;
'done: do {
    dispatch x ['zero, 'one, else 'two] {
        'two:  { r = 30; }
        'one:  { r = 20; br 'done; }
        'zero: { r = 10; br 'done; }
    }
}
```

This is the shape compilers emit for a dense switch, so decompiling WAT/Wasm to
Wax recovers `dispatch` from it (and a Wax `dispatch` round-trips through the
binary).

### Match

A `match` is a multi-way *type* test, the readable form of the nested type-test
ladder that hand-written GC code uses to take apart a value of some general
reference type. Each arm tests the scrutinee against a reference type, optionally
binding the narrowed value, and runs its body when the test succeeds:

```wax
fn classify(v: &?eq) -> i32 {
    match v {
        p: &point => { return p.x + p.y; }   // v is a &point, bound to p
        a: &bytes => { return a.length(); }  // else if v is a &bytes
        null      => { return -1; }           // else if v is null
        _         => { return 0; }            // otherwise (the default)
    }
}
```

A `x: &T` arm binds the narrowed value to `x` for its body; drop the `x:` to
test without binding. A `null` arm matches a null reference, and the required
`_` arm (as with a `dispatch`'s `else`) is the default. The scrutinee must be a
reference type; it is evaluated once.

`match` lowers to a nested ladder of blocks, one per arm plus an outer *escape*
block. The scrutinee is threaded through a `br_on_cast` (or `br_on_null` for a
`null` arm) chain in the innermost block; each test, on success, branches *out*
to its arm's block carrying the narrowed value, and the arm body follows that
block. As with `dispatch`, an arm's body must leave the `match` (here each
`return`s); to continue past it, branch to an enclosing label. When no test
matches, the chain falls through to a `br` past all the arm bodies, and the
default follows the escape block as trailing code, so reaching it falls through
to whatever comes after, including the rest of the enclosing block:

```wax
let r: i32;
'done: do {
    match v {
        p: &point => { r = p.x; br 'done; }
        a: &bytes => { r = a.length(); br 'done; }
        _ => { r = 0; }   // also reached by a non-point, non-bytes v
    }
}
```

This is the shape hand-written GC code uses, so decompiling WAT/Wasm to Wax
recovers `match` from such a ladder, even a single type test that branches out
and then falls through to a default (and a Wax `match` round-trips through the
binary).

### Return

```wax
return value;
```

### Tail Calls

Use `become` for tail calls (guaranteed not to grow the stack):

```wax,check
fn factorial_helper(n: i32, acc: i32) -> i32 {
    if n <=s 1 => i32 {
        acc;
    } else {
        become factorial_helper(n - 1, n * acc);
    }
}
```

`become` also accepts an intrinsic operation (for example `become mem.grow(n)`);
since there is no tail-call instruction for intrinsics, this is equivalent to
`return mem.grow(n)`: the intrinsic's result must match the function's result
type.

### Unreachable and Nop

`unreachable` marks code that should never run: it traps if reached. `nop` does
nothing. Neither is an expression, so neither can be bound to a name or written
as an operand. Because `unreachable` diverges, the code after it is dead and the
stack polymorphic there, so `unreachable` can satisfy any block result type,
fill any [hole](#holes) `_`, and supply any block parameter.

```wax
if x <s 0 {
    unreachable;            // this branch cannot happen
}
nop;                        // no operation
```

## Functions

### Definition

```wax
fn name(param1: type1, param2: type2) -> return_type {
    body;
}
```

Functions without a return type return nothing:

```wax,check
fn log_value(x: i32) {
    // side effects only
}
```

A function may return several values, written as a parenthesized list; the body
leaves them all on the stack, in order:

```wax,check
fn divmod(a: i32, b: i32) -> (i32, i32) {
    a /s b;
    a %s b;
}
```

### Start Function

A function marked with the `#[start]` attribute runs automatically when the
module is instantiated. It must take no parameters and return nothing, and a
module may have at most one:

```wax,check
#[start]
fn init() {
    // initialization code
}
```

Like `#[export]`, `#[start]` can carry an `if <condition>` guard, so a function
is the start only in some configurations (at most one start per configuration):

```wax,check
#[start, if(debug)]
fn init() {
    // only run under `-D debug=true`
}
```

(This maps to the WebAssembly `start` field; see
[Module Fields](./correspondence/module_fields.md#start-attribute).)

### Function Types

Function types use `fn`:

```wax,check
type binary_op = fn(i32, i32) -> i32;
```

An unnamed parameter is written as just its type:

```wax,check
type callback = fn(i32) -> i32;
```

### Calls

```wax
result = my_function(arg1, arg2);
```

### Indirect Calls

Writing a function's name without calling it is a reference to that function (a
`&func` value). This is how you get one: to store in a global or a
[table](#tables-and-element-segments), or to pass as an argument.

```wax
const handler: &callback = inc;   // a reference to `inc`, not a call
```

Call through such a reference by casting it to the expected function type:

```wax
(func_ref as &?callback)(arg)
```

## Imports and Exports

A module talks to its host through imports and exports.

**Export** a definition under a name with `#[export = "name"]`. It applies to
functions, globals, memories, tables, and tags, and a field may carry several.
The bare `#[export]` (no name) exports the field under its own Wax name:

```wax,check
#[export]
fn add(x: i32, y: i32) -> i32 { x + y; }

#[export = "PI"]
const PI: f64 = 3.14159;
```

**Import** fields from a host module with an `import "module" { … }` block. Each
entry has no body: a function is declared with just its signature, a global
with its type. It is imported under its own Wax name unless a name-only
`#[import = "name"]` overrides that:

```wax,check
import "env" {
    fn log(x: i32);
    #[import = "base_value"]
    const base: i32;
}

#[export = "run"]
fn run() { log(base); }
```

A lone import can be written on one line, `import "module" <declaration>;`:

```wax,check
import "env" fn trace(x: i32);
```

An imported field is re-exported by adding `#[export]` to its declaration.

An `#[export]` can carry an `if <condition>` guard, making just that export
[conditional](#conditional-compilation) independently of the field's own
reachability. This is how a definition can be exported under an extra name only
in some configurations:

```wax,check
#[export]
#[export = "add_alias", if(not(bootstrap))]
fn add(x: i32, y: i32) -> i32 { x + y; }
```

Here `add` is always exported under its own name, and also as `add_alias`
except when `bootstrap` holds. `#[export]` and [`#[start]`](#start-function) are
the only attributes that accept a guard.

## References

### Reference Types

A reference type is written `&type` (non-nullable) or `&?type` (nullable):

```wax
&type           // Non-nullable reference
&?type          // Nullable reference
```

`type` is either a declared type (a struct, array, [function](#function-types),
or [continuation](#stack-switching)) or one of WebAssembly's **abstract heap
types**. These form five disjoint subtype hierarchies; a reference to a type
accepts any reference to a type below it in the same tree (a `&any` accepts an
`&eq`, an `&i31`, a declared struct, and so on):

```
any     (internal / GC references)
└─ eq   (comparable with ==)
   ├─ i31
   ├─ struct
   │  └─ declared struct types
   └─ array
      └─ declared array types

func    (function references)
└─ declared function types

extern  (host references)

exn     (exceptions)

cont    (continuations)
└─ declared continuation types
```

Each hierarchy also has a **bottom** type, a subtype of everything in its tree
and inhabited only by `null`: `none` under `any`, `nofunc` under `func`,
`noextern` under `extern`, `noexn` under `exn`, and `nocont` under `cont`. So
`&any`, `&?extern`, and `&eq` are all valid reference types; see
[Types → Heap Types](correspondence/types.md#heap-types) for how each maps to
WebAssembly.

### Null

```wax
null            // Null reference (requires type context)
```

### Null Check

```wax
!ref            // True if ref is null
ref!            // Assert non-null (trap if null)
```

### Type Testing and Casting

```wax
val is &type    // Test if val is of type (returns i32)
val as &type    // Cast val to type (trap on failure)
```

Structs and arrays are WebAssembly GC heap types: a value of such a type is
always held through a reference (`&point`, `&bytes`, …), not inline.

### i31

An `i31` reference packs a 31-bit signed integer directly into a reference, with
no heap allocation. Box an `i32` with `as &i31`, and read it back with a signed
or unsigned cast:

```wax
x as &i31       // box an i32 (its low 31 bits) into a reference
r as i32_s      // read an &i31 back, sign-extended
r as i32_u      //   or zero-extended
```

`&i31` is a subtype of `&eq` and `&any`, so it can stand in wherever one of those
is expected.

## Structs

### Definition

A struct is a named record. Mark a field `mut` to allow assignment after
creation; a plain field is set only at creation time. A value of `type point`
is held as `&point`.

```wax,check
type point = { x: i32, y: i32 };
type mutable_point = { x: mut i32, y: mut i32 };
```

A field may also hold a packed storage type, `i8` or `i16`, stored in one or two
bytes rather than a full `i32`. Reading one back needs an explicit cast,
described under [Field Access](#field-access).

### Creation

`{T| …}` allocates a new struct of type `T` and yields a `&T`. Give every field
a value, or use `..` to default them all (each field type must have a zero/null
default):

```wax
{point| x: 10, y: 20}       // all fields given
{point| ..}                 // every field defaulted
```

The type name may be omitted in two cases. The first is when an expected type
supplies it: a `let`/`const` annotation, the surrounding struct or array type
(when the literal is a field value or an element), the parameter type of a
function being called (when it is an argument), or the result type of a function
or block. So `let p: &point = {x: 10, y: 20};` is equivalent to writing
`{point| …}`. Such an expectation also reaches into both
branches of a conditional `?:`, so a branch may omit the name (or default it
with `{..}`): `let p: &point = cond ? {x: 0, y: 0} : {..};`. The second is when
the **field set** names the type unambiguously: if exactly one struct type in
the module has that exact set of field names, it is inferred even with no
expected type:

```wax
fn origin() -> &eq {
    {x: 0, y: 0};               // inferred as &point from its fields
}
```

Field inference takes precedence over the expected type, so when the fields name
a subtype of the expected type, that subtype is used. The type must still be
given when the field set is ambiguous (several types share it) or absent (a
`{..}` default with no fields).

A field written as a bare name is **punned** to the like-named local or global:
`{x}` is shorthand for `{x: x}`. Punned and explicit fields mix freely, in any
order:

```wax
fn make(x: i32, y: i32) -> &point {
    {x, y: y + 1};              // same as {x: x, y: y + 1}
}
```

### Field Access

```wax
p.x                         // read a field
p.x = 42;                   // write a field (only if it is `mut`)
```

A packed (`i8`/`i16`) field is read as its raw bits, so accessing one needs an
explicit `as i32_s` (sign-extend) or `as i32_u` (zero-extend) cast; there is no
implicit widening. Storing to a packed field needs no cast, as the value is
truncated to the field width.

## Arrays

### Definition

```wax,check
type bytes = [i8];
type mutable_ints = [mut i32];
```

### Creation

```wax
[bytes| 0; 100]             // New array: 100 elements, all 0
[bytes| ..; 100]            // New array: 100 elements, default value
[bytes| 1, 2, 3, 4]         // New array with specific values
[bytes| seg @ 0; 100]       // New array from a segment (offset, count)
```

The last form builds the array from a named passive segment, copying `count`
elements starting at `offset`. For a numeric array, `seg` is a
[data segment](#data-segments) and this is `array.new_data`; for a reference
array it is an [element segment](#tables-and-element-segments) and the same
syntax is `array.new_elem`.

As with structs, the type name may be omitted when an expected type supplies it,
e.g. `let xs: &bytes = [0; 100];`.

### Element Access

```wax
arr[i]                      // Get element
arr[i] = val;               // Set element (if mutable)
arr.length()                // Array length
```

Bulk operations are method calls on the array:

```wax
arr.fill(idx, val, count)             // fill count elements from idx with val
arr.copy(idx, src, src_idx, count)    // copy from another array src
arr.init(seg, idx, src_idx, count)    // fill from a passive data/element segment
```

An element may be a packed storage type (`i8` or `i16`), like `bytes` above.
As with a [packed struct field](#field-access), reading one needs an explicit
`as i32_s`/`as i32_u` cast, while storing needs none.

## Recursive and Subtyped Types

Struct and array types can refer to one another, form subtype hierarchies, and
be left open for extension: the WebAssembly GC type features.

### Recursive Groups

Types that reference each other are declared together in a `rec { … }` group, so
each name is in scope for the others:

```wax,check
rec {
    type expr = { op: i32, args: &?args };
    type args = [mut &expr];
}
```

### Subtyping

`type sub : super` declares `sub` as a subtype of `super`: it repeats the
supertype's fields in order and may add more, and a `&sub` is accepted wherever
a `&super` is expected. Types are *final* by default; a type must be declared
`open` to be extended.

```wax,check
type shape = open { kind: i32 };
type circle : shape = { kind: i32, radius: f64 };

fn kind_of(s: &shape) -> i32 { s.kind; }   // also accepts a &circle
```

Since the inherited fields must be repeated verbatim, a leading `..` stands in
for them: it copies the supertype's field names and types, and the fields after
it are the subtype's additions. So `circle` above can be written to highlight
just its delta:

```wax,check
type shape = open { kind: i32 };
type circle : shape = { .., radius: f64 };
```

`..` must come first and appear once, and only where there is a supertype to
inherit from. An inherited field that is *renamed* or whose type is *refined*
(a covariant subtype) is no longer a verbatim copy, so it must be written out
explicitly rather than covered by `..`.

## Exact References and Descriptors

The [custom-descriptors proposal](https://github.com/WebAssembly/custom-descriptors)
adds two related features, enabled together with `-X custom-descriptors` (off by
default).

### Exact references

An **exact** reference points to values of exactly one concrete type, with no
subtypes. The exactness marker `!` goes between the `&`/`&?` sigil and the type
name, next to the nullability `?`:

```wax
&!point         // a non-null reference to exactly point
&?!point        // nullable, exactly point
```

Only a concrete (declared) type can be exact; `&!any` and other abstract heap
types are rejected. An exact reference is a subtype of the plain one, so an
`&!point` is accepted where an `&point` is expected, but exactness is invariant
across distinct concrete types. The `as` and `is` operators reach an exact type
explicitly:

```wax
x as &!point    // cast to an exact reference
x is &!point    // test for an exact type
```

Because `!` comes before the type name, it never clashes with the postfix
[non-null assertion](#null-check) `!`: `x as &!point` casts to an exact
reference, whereas `(x as &point)!` asserts the cast result is non-null.

A struct or array construction already yields an exact reference, since the new
object has exactly the allocated type, so a literal can go where an `&!point` is
expected without a cast. A module-defined function is likewise always exact; only
an **imported** function needs the marker to be treated as exact, written on the
declaration as `fn g: !ft;` (named type) or `fn h!(x: i32) -> i64;` (inline
signature). A plainly imported function is not exact, so a reference to it must
be cast to reach an exact type.

### Descriptors

A struct can carry a runtime *descriptor*: a second struct linked to it, handy
for modelling a runtime type or a vtable. The described type names its
descriptor with a `descriptor` clause, and the descriptor names what it
describes with a `describes` clause. The two are declared together in a `rec`
group:

```wax,check
rec {
    type obj = descriptor obj_desc { x: i32 };
    type obj_desc = describes obj { info: i32 };
}

#[export = "make"]
fn make(d: &!obj_desc) -> &obj {
    {descriptor(d)| x: 42};      // construct, supplying the descriptor
}

#[export = "describe"]
fn describe(o: &obj) -> &obj_desc {
    o.descriptor;                // read the descriptor back
}
```

Construction takes the descriptor as an **exact** reference (`&!obj_desc`).
Reading `.descriptor` gives an `&obj_desc`, or the exact `&!obj_desc` when the
value's own type is exact. A descriptor-based cast checks that a reference's
descriptor is a given one: `o as descriptor(d)`, or `as ?descriptor(d)` to allow
null. The [`br_on_cast` and `br_on_cast_fail`](#labels-and-branches) branches
accept the same `descriptor(d)` operand in place of a type
(`br_on_cast 'l descriptor(d) val`, with an optional `?` for the nullable form),
branching on that descriptor check. The reciprocity and rec-group rules the two
types must satisfy are listed under
[Types → Custom Descriptors](correspondence/types.md#custom-descriptors).

## Strings

A string literal builds a new array and lowers to an `array.new_fixed`. The
element type must be `i8` or `i16`, and it decides the encoding:

- an `i8` array holds the raw bytes of the (UTF-8) text, one element per byte;
- an `i16` array holds the UTF-16 code units of the text, so it must be a valid
  Unicode string (a code point outside the basic plane becomes a surrogate pair,
  hence two elements).

By default its type is `[mut i8]`:

```wax
"hello";                    // a new [mut i8] holding the 5 bytes
```

As with [array](#arrays) and [struct](#structs) literals, a different array type
can be selected: either by prefixing the string with the type name and `#`, or
by an expected type from the context:

```wax
type chars = [i8];
type wide = [i16];

chars # "hi";               // a &chars, one i8 per UTF-8 byte
wide # "café";              // a &wide, one i16 per UTF-16 code unit
let s: &chars = "yo";       // type taken from the annotation
```

String literals recognise the same escapes as [character literals](#characters):
`\t`, `\n`, `\r`, `\'`, `\"`, `\\`, `\xNN` (two hex digits, one byte), and
`\u{...}` (a Unicode code point, encoded as its UTF-8 bytes):

```wax
"tab\tend";
"smile \u{1F600}";
```

A string also supplies the bytes of a [data segment](#data-segments).

A string literal round-trips faithfully through WAT, where it is written with a
`(@string …)` annotation. Through Wasm it is best-effort: the binary keeps only
the `array.new_fixed`, which is recovered as a string literal only when its
elements, decoded by the array's element type (UTF-8 for `i8`, UTF-16 for
`i16`), form a *reasonable* string: valid text with no control characters other
than tab, newline, and carriage return. Anything else (arbitrary binary data)
decompiles as an ordinary [array literal](#arrays) instead.

## SIMD (v128)

The 128-bit vector type is `v128`. Its operations are written as method
intrinsics with the lane shape baked into the name: the Wax name is the
WebAssembly mnemonic with the leading shape moved to the end, so `i32x4.add`
becomes `add_i32x4` and `f32x4.splat` becomes `splat_f32x4`. Signed/unsigned
variants keep their `_s`/`_u` suffix, and constant lane immediates (lane and
shuffle indices) come first in the argument list.

```wax,check
fn scale(v: v128, k: i32) -> v128 {
    v.add_i32x4(k.splat_i32x4());     // i32x4.add of v and (i32x4.splat k)
}

fn lane0(v: v128) -> i32 {
    v.extract_lane_i32x4(0);          // extract lane 0
}
```

Constants are `v128::` free functions, one argument per lane:

```wax,check
const ones: v128 = v128::i32x4(1, 1, 1, 1);
```

Memory accesses are methods on a [memory](#memories), named like the scalar
accesses with the access shape in the name (a widening load keeps its
`_s`/`_u` suffix, as the value ops do); the full-width pair takes the family
letter, `loadv128`/`storev128` (like `loadf32`/`storef32`):

```wax,check
memory buf: i32 [1];

fn sum2(p: i32) -> v128 {
    let v = buf.loadv128(p);                // v128.load
    let w = buf.load32x2_s(p, offset: 16);  // v128.load32x2_s
    buf.storev128(p, v);                    // v128.store
    v.add_i64x2(w);
}
```

See [Instructions › SIMD](./correspondence/instructions.md#simd-vector-instructions) for the full
mnemonic mapping (`extract_lane`/`replace_lane`/`shuffle`, comparisons, shifts,
and the whole-vector `*_v128` operations).

## Memories

### Declaration

```wax,check
memory mem0: i32 [1, 1000];     // address type i32, min 1 page, max 1000
memory mem1: i64 [2];           // min 2 pages, no maximum
memory mem2: i32;               // size derived from data segments
```

A memory may declare a custom page size with a `pagesize` clause after its
limits. The page size is a byte count and must be `1` or `65536` (the default);
limits are then counted in pages of that size:

```wax,check
memory small: i32 [4096] pagesize 1;      // 4096 pages of 1 byte
memory mem3: i32 [1, 1000] pagesize 65536; // the default page size, explicit
```

A memory may be declared `shared` (the threads proposal), for use with atomic
accesses across threads. A shared memory must specify a maximum size:

```wax,check
memory pool: i32 [1, 16] shared;
```

### Atomics

Atomic memory operations are methods on a memory, following the same naming
convention as the plain [loads and stores](#load-and-store): the access width
is in the method name, the `i32`/`i64` value type comes from the operand and
result types, and a narrow load returns raw bits, resolved by an `as iN_u`
cast:

```wax,check
memory mem: i32 [1, 2] shared;

fn atomics(p: i32, v: i32, w: i64) -> i32 {
    _ = mem.atomic_load32(p);              // i32.atomic.load
    _ = mem.atomic_load8(p) as i32_u;      // i32.atomic.load8_u (zero-extend)
    _ = mem.atomic_load32(p) as i64_u;     // i64.atomic.load32_u
    mem.atomic_store16(p, v);              // i32.atomic.store16 (v is i32)
    mem.atomic_store16(p, w);              // i64.atomic.store16 (w is i64)
    _ = mem.atomic_rmw_add32(p, v);        // read-modify-write: the old value
    _ = mem.atomic_rmw_add16(p, w);        // i64.atomic.rmw16.add_u
    _ = mem.atomic_rmw_cmpxchg32(p, v, v); // compare-and-exchange
    _ = mem.atomic_wait32(p, v, w);        // wait: expected value and timeout
    mem.atomic_notify(p, 1);               // wake waiters: how many woke
}
```

A narrow atomic load zero-extends: there is no sign-extending form, so
`as iN_s` is rejected on it (use `as iN_u`, then `.extend8_s()`/`.extend16_s()`
if you need the sign; `atomic_load32(p) as i64_s` compiles as the plain
`i32.atomic.load` followed by `i64.extend_i32_s`). An atomic access must use
its natural alignment, the access width from the name. `atomic.fence`, which
has no memory operand, is written as the
[`atomic::fence()`](#qualified-intrinsics) intrinsic.

### Data Segments

```wax
memory mem1: i64 {
    data _ @ [0x1000] = "hello world";   // active, anonymous
    data greeting @ [0x2000] = "hi";     // active, named
}

data seg = "raw\x00bytes";               // top-level passive segment
data init @ mem0 [0] = "hello";          // top-level active segment
```

A segment's contents may concatenate (with `++`) string literals and **numeric
runs** — a bracketed list `[type: values]` whose element type is stated once
and whose values are packed little-endian — instead of hand-escaping every
byte:

```wax
data table = "hdr" ++ [f32: 0.2, 0.3, 0.4] ++ [i16: -1, -2] ++ [i8: 1, 2, 3, 4];
```

The scalar element types are `i8`, `i16`, `i32`, `i64`, `f32`, and `f64`; values
(including `nan`/`inf`) are ordinary literals. A `v128` run holds lane groups
written `shape(lanes)`:

```wax
data vectors = [v128: i32x4(1, 2, 3, 4), f64x2(1.0, 2.0)];
```

### Load and Store

```wax
mem0.load32(p)              // i32 load
mem0.load64(p)              // i64 load
mem0.load8(p) as i32_u      // narrow load, zero-extended
mem0.load16(p) as i32_s     // narrow load, sign-extended
mem0.load32(p) as i64_s     // load then widen to i64

mem0.store32(p, v);         // store (width by method, type by value)
mem0.store16(p, v);
mem0.store32(p, v, offset: 16, align: 1);
```

The optional `offset` and `align` of the access are labelled arguments
(constant integers), written after the operands in either order.

A `load8` or `load16` returns raw bits, so it needs an explicit `as i32_s`/`as i32_u`
(or `as i64_s`/`as i64_u`) cast to extend to the value type, as the lines above
show; `load32`/`load64` and the stores need none.

## Tables and Element Segments

A table holds references and is indexed like an array. Element segments declare lists of references, optionally initializing a table.

```wax
table funcs: &?func [1, 10];          // table of function references
elem init: &?func @ funcs[0] = [f];   // active: initialize funcs at offset 0
elem pool: &?func = [f, g, h];        // passive segment

funcs[i]                              // table.get
funcs[i] = g;                         // table.set
(funcs[i] as &cmp)(x, y)              // indirect call (call_indirect)
```

The table-management instructions are method calls on the table (and `drop` on
an element segment):

```wax
funcs.size()                          // current size
funcs.grow(init, n)                   // grow by n, filling with init; returns the old size
funcs.fill(dst, val, n)               // set n slots from dst to val
funcs.copy(dst, src, n)               // copy n slots within the table
funcs.init(pool, dst, src, n)         // copy n refs from element segment pool
pool.drop();                          // drop a passive element segment
```

A passive element segment initializes a GC array of references with the same `[t| seg @ off; count]` form used for data segments; a reference element type selects the element segment:

```wax
[handlers| pool @ 0; 3]               // array.new_elem
```

## Exceptions

### Tags

A tag declares an exception, optionally carrying a payload. The parameter list
is required; write `()` for no payload:

```wax,check
tag stop();                 // no payload
tag overflow(i32);          // carries an i32
tag pair(i32, f64);         // carries several values
```

A tag may also declare a **result type**, written like a function signature.
This is used by [stack switching](#stack-switching): resuming a suspended
continuation hands this value back to the `suspend` expression.

```wax,check
tag yield(i32) -> i32;      // carries an i32; resumes with an i32
```

### Throw

`throw` raises a tag together with its payload:

```wax
throw overflow(42);
```

### Try / Catch

A `try` runs its body and routes a matching thrown tag to a catch arm,
compiling to WebAssembly's standard `try_table` plus a block ladder. Like a
block it may carry a result type (`try i32 { … }`). An arm enters with the
caught tag's payload on the operand stack, picked up with [holes](#holes) `_`;
a `tag & => { … }` arm also delivers the exception reference (`&exn`) above
the payload, and a bare `_ => { … }` (or `_ & => { … }`) matches any
exception, grammar-enforced last. Leave the catch-all out to let unmatched
exceptions propagate.

Like `dispatch` and `match`, the arms are honest trailing code in clause
order:

- the body's normal completion **escapes past all arms**, supplying the try's
  value (one implicit branch);
- an arm's completion **falls into the next arm** — its completion stack must
  match that arm's entry (payload, plus `&exn` for a `&` arm) — and the last
  arm's completion supplies the try's value;
- diverging arms (`throw`, `return`, `become`, a `br` out) are exempt, as
  usual.

An early arm that produces the result escapes explicitly through a label on
the try: the label is the join, so branching to it exits the try carrying the
value, block-like. (In expression position no label can prefix the try, so
such an arm must diverge, or the code restructures.)

```wax
fn lookup(k: i32) -> i32 {
    't: try i32 {
        find(k);                     // may throw `overflow` or `timeout`
    } catch {
        overflow => { br 't _; }     // `_` is the thrown i32 payload
        timeout & => { _ = _; br 't (0 - 1); }  // drop the &exn, escape
        _ => { 0; }                  // catch-all supplies the value
    }
}
```

The fall-through makes the *normalize, then handle* idiom direct — the first
arm's completion **is** the next arm's payload, with no re-throw:

```wax
let res: &eq = try &eq {
    apply(f);
} catch {
    javascript_exception => { wrap_exception(_); }  // normalize; falls through
    ocaml_exception => { _; }                       // handle either
};
```

### Branching handlers (try_table)

The low-level spelling branches to a label instead of running an inline arm,
mapping one-to-one to a raw `try_table`:

```wax
try { might_throw(); } catch [overflow -> 'h]    // on `overflow`, branch to 'h
try { might_throw(); } catch [overflow & -> 'h]  // also deliver the exnref
try { might_throw(); } catch [_ -> 'h]           // catch any exception
```

The target label receives the payload (and, with `&`, the exception reference,
of type `&exn`, or `&?exn` for the nullable form), so the labelled block's type
must match what it is handed. Braced arms are the same clauses with the
target blocks written inline.

### Legacy exceptions (try_legacy)

`try_legacy` compiles to the deprecated `try`/`catch` instructions, kept for
targets that still use the legacy exception proposal. Its arms have the old
semantics — each arm independently produces the try's result (no fall-through,
no `&` forms):

```wax
try_legacy i32 { find(k); } catch { overflow => { _; } _ => { 0; } }
```

## Stack Switching

*Stack switching* (the WebAssembly typed-continuations proposal) lets a
computation suspend itself, yield control to a scheduler, and later be resumed.
A **continuation type** wraps a function type with `cont`:

```wax,check
type task = fn(i32) -> i32;
type k = cont task;
```

A [tag with a result type](#tags) is the suspend/resume channel: `suspend`
passes the tag's payload out and evaluates to its result once resumed.

```wax,check
tag yield(i32) -> i32;

fn worker(x: i32) -> i32 {
    suspend yield(x);          // yield `x`; the result is what resumes it
}
```

A continuation is created with the `T::new` constructor of its declared type
(the `T::` namespace constructs a `&T`, extending the `v128::`/`i64::`
qualified-intrinsic pattern), and driven with the `resume`, `resume_throw` and
`resume_throw_ref` methods on the continuation reference. `T::bind` binds
leading arguments away, yielding a `&T`; its source type, like the type
immediate of the resume methods, is inferred from the continuation operand's
static type — the call_ref model, so the receiver must have a *declared*
continuation type.

Continuations carry no runtime type information, so `as` with a continuation
target is a *compile-time ascription*, not a cast: it is accepted exactly when
it is a provable no-op — the operand's type is already a subtype of the target
(`(c as &k0).resume(x)` resumes through the supertype signature, selecting the
`resume $k0` immediate), a `null` literal with a nullable target, or dead code
the ascription pins — and it compiles to no instruction. A `&cont` can never
be *narrowed*: an abstract reference cannot be resumed, and no cast can fix it,
so give the value its precise type where it is introduced (a parameter, local
or block-result annotation). `is` and `br_on_cast` reject continuation targets
outright (they are inherently runtime tests).

```wax
type unit_task = fn() -> i32;
type k0 = cont unit_task;

fn spawn() -> &k { k::new(worker); }        // wrap `worker` (a task)
fn prime(c: &k) -> &k0 { k0::bind(7, c); }  // bind the argument
fn go(c: &k0) -> i32 { c.resume(); }        // run until it suspends
```

Handlers routing a suspended tag to a label are a postfix `on` clause on the
call, a bracket of `tag -> 'label` or `tag -> switch` arms (the same shape and
placement as `try { … } catch [t -> 'l]`), omitted when empty:

```wax
c.resume(x) on [yield -> 'on_yield]
```

The abstract continuation heap types are written `&cont` and `&nocont` (with
`&?cont` for the nullable form).

`c.switch(args, tag: t)` hands control straight to another continuation `c`
instead of suspending back to a handler, passing `args` and the current
continuation; the enabling tag is the required labelled `tag:` immediate, and
the `resume` that drives things enables it with a `t -> switch` arm in its
handler list.

The receiver of these methods compiles *last*: operands compile in the
instruction's stack order, which for continuations — as for `call_ref` — puts
the receiver after the arguments.

## Holes

A hole (`_`) is a placeholder for a value that an **earlier statement in the
same sequence** has left on WebAssembly's implicit operand stack. It is the
surface syntax for that stack flow: rather than naming an intermediate value,
you leave a hole where it should be plugged in.

```wax,check
fn example() -> i32 {
    1; 2; _ + _;    // Equivalent to: let a = 1; let b = 2; a + b
}
```

Here the statements `1` and `2` each push a value; the two holes in `_ + _`
consume them.

**How many, and in what order.** The number of holes in an expression is the
number of stack values it pulls in. They are filled **left-to-right with the
stack values in the order those values were produced**: the earliest value
fills the leftmost hole. Order therefore matters for non-commutative
operators:

```wax,check
fn diff() -> i32 {
    10; 20; _ - _;    // 10 - 20, not 20 - 10
}
```

A single hole is common when combining one stacked value with an explicit
operand:

```wax,check
fn add_one(x: i32) -> i32 {
    x; _ + 1;
}
```

**Holes must come first.** Within an expression, every hole must precede (in
evaluation order) any explicit value-producing operand. Once a non-hole operand
appears, no further holes may follow it. Explicit operands *after* all the holes
are fine:

```wax,check
fn ok() -> i32 {
    1; 2; _ + _ + 3;    // OK: the literal 3 comes after both holes
}
```

but an explicit operand wedged *before* an unfilled hole is rejected:

```wax
fn bad() -> i32 {
    2; 3; _ + 3 + _;    // Error: This expression occurs before a hole '_'.
}
```

This restriction keeps holes unambiguous: they always refer to values already on
the stack, never to operands appearing later in the expression.

**Not every position accepts a hole.** The scrutinee of a
[`match`](#match), the index of a [`dispatch`](#dispatch), and the condition of a
[`while`](#while-loops) cannot be a hole. Each of these desugars to a
nested block structure, and a hole inside a block draws only from that block's
own stack, not from the values pending in the enclosing sequence, so there is
nothing there for it to pick up:

```wax
fn bad(x: &any) {
    x; match _ { … }    // Error: A hole '_' cannot be used as a 'match' scrutinee.
}
```

When decompiling Wasm or WAT back to Wax, the compiler introduces holes wherever
an instruction takes an operand from the stack instead of from a nested
sub-expression, so this same mechanism round-trips stack-style code.

## Conditional Compilation

Top-level items can be guarded by conditions, using a Rust-like attribute syntax. `#[if(<condition>)] { ... }` keeps the braced items only when `<condition>` holds; an optional `#[else] { ... }` provides an alternative. The braces are required:

```wax,check
#[if(ocaml_version >= (5, 1, 0))]
{
    const caml_marshal_header_size: i32 = 16;
}
#[else]
{
    const caml_marshal_header_size: i32 = 20;
}
```

A condition is one of:

- a **boolean variable**, e.g. `debug`;
- a **comparison** `variable op literal`, where `op` is `=`, `!=`, `<`, `<=`, `>` or `>=`, and the literal is either a **version** tuple `(major, minor, patch)` or a **string** `"..."`:

  ```text
  feature = "gc"
  ocaml_version >= (5, 1, 0)
  ```

- a **combination** built with `all(...)` (conjunction), `any(...)` (disjunction) or `not(...)` (negation), nested arbitrarily:

  ```text
  all(debug, not(target = "wasm32"))
  ```

A branch groups any number of items, so several can be guarded at once:

```wax,check
#[if(debug)]
{
    const debug_enabled: i32 = 1;
    fn debug_log(msg: i32) {
        // ...
    }
}
```

The same `#[if(...)] { ... }` / `#[else] { ... }` form also guards **statements** inside a function body:

```wax,check
fn size() -> i32 {
    #[if(debug)]
    {
        return 16;
    }
    #[else]
    {
        return 20;
    }
}
```

These two are the only levels at which conditional compilation applies: whole module items and whole statements. A condition cannot guard part of an expression. The one finer-grained case is the `if <condition>` guard on an [`#[export]`](#imports-and-exports) or [`#[start]`](#start-function), which makes a single export (or the start) conditional without wrapping its definition in an `#[if]` block; its condition is simplified against any enclosing `#[if]` and resolved by `-D` just like a block condition.

A statement-level branch cannot introduce a local with `let`, since the two branches are mutually exclusive and a binding made in one would not be in scope after the conditional. Declare the local before the conditional and assign to it inside each branch instead:

```wax,check
fn size() -> i32 {
    let s: i32;
    #[if(debug)]
    {
        s = 16;
    }
    #[else]
    {
        s = 20;
    }
    return s;
}
```

The conditions are **not evaluated** by the compiler; they are preserved for a downstream preprocessor. The `#[if]` and `#[else]` branches are **mutually exclusive** (they never coexist), so, for instance, the same name may be defined in both.

Variables can be given values on the command line with [`-D`/`--define`](cli.md), which specializes the conditionals: a condition that becomes fully determined causes its conditional to be removed (the surviving branch is spliced in), and one that still mentions unset variables is kept with its condition simplified. For example, `wax -D debug=true` turns `#[if(all(debug, target = "wasi"))]` into `#[if(target = "wasi")]`, and `wax -D debug=false` removes that conditional altogether.

When type checking is enabled (`--validate`), every reachable combination of conditions is checked independently. Because branches are mutually exclusive, a name defined in both the `#[if]` and `#[else]` branch is accepted. An error that occurs only under some conditions is reported together with the assumption that makes it reachable:

```
Error: This instruction has type float but is expected to have type i32.
 ──➤  example.wax:4:16
Hint: reachable when not debug
```


<!-- docs/src/cheatsheet.md -->

# Cheat Sheet

A terse syntax reference. See the [Language Guide](./language.md) for the full
explanations, and [Correspondence](./correspondence/intro.md) for the mapping to
WebAssembly.

## Types

```wax
i32  i64  f32  f64        // numbers
v128                      // SIMD vector
i8   i16                  // packed storage (struct fields / array elements only)
&t   &?t                  // reference: non-null / nullable
&!t  &?!t                 // exact reference (-X custom-descriptors)
```

Abstract heap types: `any eq i31 struct array func extern exn cont`, and the
bottom types `none nofunc noextern noexn nocont`.

## Literals

```wax
42  0x2A  // integers (flexible: i32/i64/f32/f64 by context)
3.14  1.0e10  0x1.5p3  inf  nan   // floats
'A'  '\n'  '\u{1F600}'    // char, an i32 code point
"text"  bytes # "text"    // string, an i8/i16 array
```

## Variables

```wax
let x: i32 = 0;           // local (type or initializer may be omitted)
let (q, r) = divmod(a);   // bind several results
const PI: f64 = 3.14;     // immutable global
let counter: i32 = 0;     // mutable global
x = 1;                    // assign
x := 1;                   // assign and yield the value (locals only)
x += 1;                   // compound: += -= *= /= /s= /u= %s= %u= &= |= ^= <<= >>s= >>u=
_ = e;                    // evaluate and discard
```

## Operators

```wax
+  -  *  /  /s  /u  %s  %u       // arithmetic (/ is float division)
&  |  ^  <<  >>s  >>u            // bitwise
==  !=  <  <s  <u  <=  <=s  ...  // comparison (== / != on refs is identity)
-x   !x                         // negate / logical not (eqz)
```

## Type operations

```wax
e as t          // cast or convert (as i32_s / as i32_u for signedness)
e is &t         // type test, yields i32
!ref            // true if null
ref!            // assert non-null (traps if null)
x as &i31       // box an i32; read back with as i32_s / as i32_u
```

## Control flow

```wax
if c { } else { }                    // conditional statement
c ? a : b                            // conditional expression
do { }        'l: do t { }           // block (optionally labeled / typed)
loop { }                             // loop
while c { }   'l: while c : (step) { }   // while (optional continue-expression)
br 'l;   br_if 'l c;   br_table ['a, 'b, else 'd] i;
br_on_null 'l v;   br_on_cast 'l &t v;   // also _non_null / _cast_fail
dispatch i ['a, 'b, else 'd] { 'a: { } 'b: { } 'd: { } }   // jump table (falls through)
match v { p: &t => { }  null => { }  _ => { } }          // type match
return e;   become f(x);             // return / tail call
unreachable;   nop;                  // trap / no-op (statements, not expressions)
```

## Functions

```wax
fn f(x: i32, y: i32) -> i32 { x + y; }   // definition
fn g(x: i32) -> i32;                     // declaration (for imports)
f(a, b)                                  // call
(fref as &?ft)(a, b)                     // indirect call through a reference
```

## Structs and arrays

```wax
type point = { x: i32, y: mut i32 };     // struct (mut = assignable)
{point| x: 1, y: 2}   {x, y}   {..}      // create (name optional; punned; defaulted)
p.x        p.x = 1;                      // field access

type bytes = [mut i8];                   // array
[bytes| 0; n]   [1, 2, 3]   [t| seg @ off; n]   // create (last is new_data/new_elem)
a[i]   a[i] = v;   a.length()            // element access
a.fill(i, v, n)   a.copy(i, src, si, n)   a.init(seg, i, si, n)
```

## Module fields

```wax
memory m: i32 [min, max];                // memory (optional: pagesize N, shared)
table t: &?func [min, max];              // table
data d = "bytes";                        // data segment
elem e: &?func = [f, g];                 // element segment
tag oops(i32);                           // exception tag
import "env" { fn log(x: i32); }         // import block
#[export = "name"] fn f() { }            // export
#[start] fn init() { }                   // start function
#[if(cond)] ... #[else] ...              // conditional compilation
```

## Memory access

```wax
m.load32(p)   m.load8(p) as i32_u   m.store16(p, v);   // load / store (width in name)
m.size()   m.grow(n)   m.fill(d, v, n)   m.copy(d, s, n)   // management
```

## Exceptions and stack switching

```wax
try t { } catch { oops => { _; } }               // try / catch arms (payload via hole _)
try_legacy t { } catch { oops => { _; } }        // deprecated try/catch instructions
throw oops(42);                                   // throw
try { } catch [oops -> 'h]                       // branch-to-label form (try_table)
type k = cont ft;                                // continuation type
let c = k::new(f);                               // cont.new (k::bind binds args)
suspend yield(x);   c.resume(args) on [tag -> 'l];    // suspend / resume
```


<!-- docs/src/examples.md -->

# Examples

Complete examples demonstrating Wax features and their WebAssembly equivalents.

## Named Module

A `#![module = "..."]` inner attribute names the module.

### Wax

```wax
#![module = "calculator"]

#[export = "square"]
fn square(x: i32) -> i32 {
    x * x;
}
```

### Equivalent WAT

```wat,check
(module $calculator
  (func $square (export "square") (param $x i32) (result i32)
    local.get $x
    local.get $x
    i32.mul))
```

## Feature Declaration

A `#![feature = "..."]` inner attribute declares an optional proposal the
module uses, so it compiles and validates with no `-X` flag.

### Wax

```wax
#![feature = "custom-descriptors"]

rec {
    type obj = descriptor obj_desc { x: i32 };
    type obj_desc = describes obj { };
}
```

### Equivalent WAT

```wat,check
(module
  (@feature "custom-descriptors")
  (rec
    (type $obj (descriptor $obj_desc) (struct (field $x i32)))
    (type $obj_desc (describes $obj) (struct))))
```

## Arithmetic Functions

### Wax

```wax
#[export = "add"]
fn add(x: i32, y: i32) -> i32 {
    x + y;
}

#[export = "multiply"]
fn multiply(x: i32, y: i32) -> i32 {
    x * y;
}
```

### Equivalent WAT

```wat,check
(func $add (export "add") (param $x i32) (param $y i32) (result i32)
  local.get $x
  local.get $y
  i32.add)

(func $multiply (export "multiply") (param $x i32) (param $y i32) (result i32)
  local.get $x
  local.get $y
  i32.mul)
```

## Factorial with Recursion

### Wax

```wax
#[export = "factorial"]
fn factorial(n: i32) -> i32 {
    if n <=s 1 => i32 {
        1;
    } else {
        n * factorial(n - 1);
    }
}
```

### Equivalent WAT

```wat,check
(func $factorial (export "factorial") (param $n i32) (result i32)
  local.get $n
  i32.const 1
  i32.le_s
  if (result i32)
    i32.const 1
  else
    local.get $n
    local.get $n
    i32.const 1
    i32.sub
    call $factorial
    i32.mul
  end)
```

## Factorial with Tail Call

### Wax

```wax
#[export = "factorial"]
fn factorial(n: i32) -> i32 {
    become factorial_helper(n, 1);
}

fn factorial_helper(n: i32, acc: i32) -> i32 {
    if n <=s 1 => i32 {
        acc;
    } else {
        become factorial_helper(n - 1, n * acc);
    }
}
```

## Loop with Early Exit

### Wax

```wax
type ints = [i32];

#[export = "find_first_zero"]
fn find_first_zero(arr: &ints) -> i32 {
    let len = arr.length();
    let i = 0;
    'search: loop {
        if i >=s len {
            return -1;
        }
        if arr[i] == 0 {
            return i;
        }
        i += 1;
        br 'search;
    }
    unreachable;
}
```

### Equivalent WAT

```wat
(func $find_first_zero (export "find_first_zero")
      (param $arr (ref $array_i32)) (result i32)
  (local $len i32)
  (local $i i32)
  local.get $arr
  array.len
  local.set $len
  i32.const 0
  local.set $i
  (loop $search
    local.get $i
    local.get $len
    i32.ge_s
    if
      i32.const -1
      return
    end
    local.get $arr
    local.get $i
    array.get $array_i32
    i32.eqz
    if
      local.get $i
      return
    end
    local.get $i
    i32.const 1
    i32.add
    local.set $i
    br $search))
```

## While Loops

### Wax

```wax
#[export = "triangle"]
fn triangle(n: i32) -> i32 {
    let i: i32 = 0;
    let total: i32 = 0;
    while i <s n {
        i += 1;
        total += i;
    }
    total;
}

#[export = "countdown"]
fn countdown(n: i32) -> i32 {
    let steps: i32 = 0;
    'loop: loop {
        n -= 1;
        steps += 1;
        br_if 'loop n >s 0;
    }
    steps;
}
```

### Equivalent WAT

```wat,check
(func $triangle (export "triangle") (param $n i32) (result i32)
  (local $i i32) (local $total i32)
  (local.set $i (i32.const 0))
  (local.set $total (i32.const 0))
  (loop $loop
    (if (i32.lt_s (local.get $i) (local.get $n))
      (then
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $total (i32.add (local.get $total) (local.get $i)))
        (br $loop))))
  (local.get $total)
)

(func $countdown (export "countdown") (param $n i32) (result i32)
  (local $steps i32)
  (local.set $steps (i32.const 0))
  (loop $loop
    (local.set $n (i32.sub (local.get $n) (i32.const 1)))
    (local.set $steps (i32.add (local.get $steps) (i32.const 1)))
    (br_if $loop (i32.gt_s (local.get $n) (i32.const 0))))
  (local.get $steps)
)
```

## Dispatch (Jump Table)

### Wax

```wax
#[export = "rgb_channel"]
fn rgb_channel(color: i32, value: i32) -> i32 {
    dispatch color ['red, 'green, 'blue, else 'bad] {
        'bad:   { return -1; }
        'blue:  { return value & 255; }
        'green: { return (value & 255) << 8; }
        'red:   { return (value & 255) << 16; }
    }
}
```

### Equivalent WAT

```wat,check
(func $rgb_channel (export "rgb_channel")
  (param $color i32) (param $value i32) (result i32)
  (block $red
    (block $green
      (block $blue
        (block $bad (br_table $red $green $blue $bad (local.get $color)))
        (return (i32.const -1)))
      (return (i32.and (local.get $value) (i32.const 255))))
    (return
      (i32.shl (i32.and (local.get $value) (i32.const 255)) (i32.const 8))))
  (return
    (i32.shl (i32.and (local.get $value) (i32.const 255)) (i32.const 16))))
```

## Type Match

### Wax

```wax
type cell = { value: i32 };
type cons = { head: &eq, tail: &?eq };

#[export = "sum_list"]
fn sum_list(v: &?eq) -> i32 {
    match v {
        c: &cons => { return (c.head as &cell).value + sum_list(c.tail); }
        x: &cell => { return x.value; }
        _ => { return 0; }
    }
}
```

### Equivalent WAT

The scrutinee is evaluated once and threaded through a `br_on_cast` chain in the
innermost block; each test branches out to its arm's block (named by a readable
`$arm`/`$default` label, picked fresh so it cannot capture a user branch)
carrying the narrowed value, and the default trails the outer escape block:

```wat
(func $sum_list (export "sum_list") (param $v eqref) (result i32)
  (local $x (ref $cell)) (local $c (ref $cons))
  (block $default
    (local.set $x
      (block $arm_1 (result (ref $cell))
        (local.set $c
          (block $arm (result (ref $cons))
            (drop
              (br_on_cast $arm_1 eqref (ref $cell)
                (br_on_cast $arm eqref (ref $cons) (local.get $v))))
            (br $default)))
        (return
          (i32.add
            (struct.get $cell $value
              (ref.cast (ref $cell) (struct.get $cons $head (local.get $c))))
            (call $sum_list (struct.get $cons $tail (local.get $c)))))))
    (return (struct.get $cell $value (local.get $x))))
  (return (i32.const 0)))
```

## Structs and Methods

### Wax

```wax
type point = { x: i32, y: i32 };

#[export = "make_point"]
fn make_point(x: i32, y: i32) -> &point {
    {point| x, y};             // field shorthand: {x, y} means {x: x, y: y}
}

#[export = "distance_squared"]
fn distance_squared(p1: &point, p2: &point) -> i32 {
    let dx = p1.x - p2.x;
    let dy = p1.y - p2.y;
    dx * dx + dy * dy;
}
```

## Mutable Structs

### Wax

```wax
type counter = { value: mut i32 };

#[export = "new_counter"]
fn new_counter() -> &counter {
    {counter| value: 0};
}

#[export = "increment"]
fn increment(c: &counter) {
    c.value = c.value + 1;
}

#[export = "get_value"]
fn get_value(c: &counter) -> i32 {
    c.value;
}
```

## Inferring Struct and Array Types

### Wax

```wax
type point = { x: i32, y: i32 };
type ints = [mut i32];

// Where an expected type fixes the result (here a `let` annotation) the
// struct or array type name may be omitted.
#[export = "origin"]
fn origin() -> &point {
    let p: &point = {x: 0, y: 0};
    p;
}

#[export = "zeros"]
fn zeros() -> &ints {
    let a: &ints = [0; 16];
    a;
}

// A struct type can also be inferred from its field set alone, with no
// expected type: only `point` has the fields {x, y}, so its name may be
// dropped here too.
#[export = "make_origin"]
fn make_origin() -> &eq {
    {x: 0, y: 0};
}

// The expected type also reaches into both branches of a conditional `?:`, so a
// branch may omit the name: here the `{..}` default is resolved from the
// `-> &point` result type flowing through the `?:`.
#[export = "pick"]
fn pick(c: i32) -> &point {
    c ? {..} : {x: 1, y: 2};
}
```

## Inferring Block Result Types

### Wax

A block's result type, `=> T` on an `if`, or the type after `do` (and likewise
`loop`, `try`, and `try_table`), may be omitted where it is fixed by the values
the block produces or by the surrounding context:

```wax
#[export = "max0"]
fn max0(n: i32) -> i32 {
    // `=> i32` omitted: inferred from the branches and the return type
    if n <s 0 {
        0;
    } else {
        n;
    }
}

#[export = "answer"]
fn answer() -> i32 {
    // the `do` block's result type is inferred from the value it leaves
    let x = do {
        40 + 2;
    };
    x;
}
```

## Arrays

### Wax

```wax
type bytes = [mut i8];

#[export = "sum_bytes"]
fn sum_bytes(arr: &bytes) -> i32 {
    let sum = 0;
    let i = 0;
    let len = arr.length();
    'loop: loop {
        if i >=s len {
            return sum;
        }
        sum += arr[i] as i32_u;
        i += 1;
        br 'loop;
    }
    unreachable;
}

#[export = "fill_bytes"]
fn fill_bytes(arr: &bytes, val: i32) {
    let i = 0;
    let len = arr.length();
    'loop: loop {
        if i >=s len {
            return;
        }
        arr[i] = val;
        i += 1;
        br 'loop;
    }
}
```

## Exception Handling

### Wax

```wax
tag divide_by_zero();
tag overflow();

#[export = "safe_divide"]
fn safe_divide(a: i32, b: i32) -> i32 {
    if b == 0 {
        throw divide_by_zero();
    }
    a /s b;
}

#[export = "try_divide"]
fn try_divide(a: i32, b: i32) -> i32 {
    try i32 {
        safe_divide(a, b);
    } catch {
        divide_by_zero => { 0; }   // return 0 on division by zero
    }
}
```

## Recursive Types (Linked List)

### Wax

```wax
type list = { value: i32, next: &?list };

#[export = "make_node"]
fn make_node(value: i32, next: &?list) -> &list {
    {list| value, next};
}

#[export = "sum_list"]
fn sum_list(head: &?list) -> i32 {
    if !head {
        return 0;
    }
    let n = head!;
    n.value + sum_list(n.next);
}
```

## Imports and Exports

### Wax

```wax
// Import a function and a global from the host environment
import "env" {
    fn log(value: i32);
    const base_value: i32;
}

// Export a function that uses the imports
#[export = "compute_and_log"]
fn compute_and_log(x: i32) -> i32 {
    let result = x + base_value;
    log(result);
    result;
}
```

## Hash Function

A more complex example showing bitwise operations:

### Wax

```wax
#[export = "hash_mix_int"]
fn hash_mix_int(h: i32, d: i32) -> i32 {
    ((d * 0xcc9e2d51).rotl(15) * 0x1b873593 ^ h).rotl(13) * 5 + 0xe6546b64;
}

#[export = "hash_finalize"]
fn hash_finalize(h: i32) -> i32 {
    h ^= h >>u 16;
    h *= 0x85ebca6b;
    h ^= h >>u 13;
    h *= 0xc2b2ae35;
    h ^ h >>u 16;
}
```

## Strings and Characters

A character literal is an `i32` code point; a string literal builds an `i8` or
`i16` array (`[mut i8]` by default, or a named array type with the `T # "…"`
prefix). An `i8` array holds the raw UTF-8 bytes; an `i16` array holds the
UTF-16 code units. See [Strings](language.md#strings).

### Wax

```wax
type chars = [i8];
type wide = [i16];

#[export = "newline"]
fn newline() -> i32 {
    '\n';                       // 10
}

#[export = "greeting"]
fn greeting() -> &chars {
    chars # "hi\u{21}";         // the bytes 'h', 'i', '!'
}

#[export = "wide_greeting"]
fn wide_greeting() -> &wide {
    wide # "café";              // the UTF-16 units 'c', 'a', 'f', 'é'
}
```

### Equivalent WAT

`wax -f wat` keeps the literals as `(@char …)` / `(@string …)` annotations, so
they round-trip back to Wax unchanged:

```wat
(func $newline (export "newline") (result i32) (@char "\n"))

(func $greeting (export "greeting") (result (ref $chars))
  (@string $chars "hi!"))

(func $wide_greeting (export "wide_greeting") (result (ref $wide))
  (@string $wide "café"))
```

In a Wasm binary these lower to `i32.const 10` and an `array.new_fixed`: the
`i8` greeting holds the three bytes `104, 105, 33`, and the `i16` greeting the
four UTF-16 units `99, 97, 102, 233`. The character comes back as the integer
`10`, while each string is still recovered (its elements are reasonable text).

## Holes (Stack Values)

Holes (`_`) plug in values that earlier statements leave on the operand stack.
The two holes in `_ + _` consume `x * 2` and `y * 3`, left-to-right in the order
they were produced. See [Holes](language.md#holes) for the full rules.

### Wax

```wax
#[export = "blend"]
fn blend(x: i32, y: i32) -> i32 {
    x * 2;
    y * 3;
    _ + _;
}
```

### Equivalent WAT

```wat,check
(func $blend (export "blend") (param $x i32) (param $y i32) (result i32)
  local.get $x
  i32.const 2
  i32.mul
  local.get $y
  i32.const 3
  i32.mul
  i32.add)
```

## Multiple Return Values

A function may return several values, and a `let` can bind them all at once
from a parenthesised list of names. The call runs once and its results are
stored into the locals. See [Local Variables](language.md#local-variables).

### Wax

```wax
fn divmod(a: i32, b: i32) -> (i32, i32) {
    a /s b;
    a %s b;
}

#[export = "checksum"]
fn checksum(a: i32, b: i32) -> i32 {
    let (q, r) = divmod(a, b);
    q + r;
}
```

### Equivalent WAT

```wat,check
(func $divmod (param $a i32) (param $b i32) (result i32 i32)
  local.get $a
  local.get $b
  i32.div_s
  local.get $a
  local.get $b
  i32.rem_s)

(func $checksum (export "checksum") (param $a i32) (param $b i32) (result i32)
  (local $q i32) (local $r i32)
  local.get $a
  local.get $b
  call $divmod
  local.set $r
  local.set $q
  local.get $q
  local.get $r
  i32.add)
```

## Wide Arithmetic

128-bit integer arithmetic uses the `i64::` intrinsics, which take and return
their operands as `(low, high)` pairs of `i64` values. Each returns two
results, so a multi-value `let` binds them.

### Wax

```wax
#[export = "add_u128"]
fn add_u128(a_lo: i64, a_hi: i64, b_lo: i64, b_hi: i64) -> (i64, i64) {
    let (lo, hi) = i64::add128(a_lo, a_hi, b_lo, b_hi);
    lo;
    hi;
}

#[export = "mul_u64_to_u128"]
fn mul_u64_to_u128(a: i64, b: i64) -> (i64, i64) {
    i64::mul_wide_u(a, b);
}
```

## Custom Descriptors

A struct can carry a *descriptor*: a second struct linked to it by reciprocal
[`descriptor`/`describes` clauses](correspondence/types.md#descriptors). The
descriptor instructions never name the target type: it is recovered from the
descriptor operand (the type the operand *describes*), so all of them share one
`descriptor(d)` clause. `struct.new_desc` allocates carrying a descriptor,
`.descriptor` reads it back, and `as [?]descriptor(d)` / `br_on_cast [?]descriptor(d)`
cast on descriptor equality (a leading `?` makes the result nullable).

### Wax

```wax
rec {
    type obj = descriptor obj_desc { x: i32 };
    type obj_desc = describes obj { kind: i32 };
}

#[export = "make"]
fn make(kind: i32, x: i32) -> &!obj {
    { descriptor({obj_desc| kind})| x };
}

#[export = "kind_of"]
fn kind_of(o: &obj) -> i32 {
    o.descriptor.kind;
}

#[export = "narrow"]
fn narrow(v: &?any, d: &!obj_desc) -> &?obj {
    v as ?descriptor(d);
}
```

## Branch hints

The [branch-hinting proposal](correspondence/instructions.md#branch-hints) marks
a conditional branch likely or unlikely taken. Prefix the branch with
`#[likely]` / `#[unlikely]`; the hint is preserved through every conversion (no
feature flag required).

### Wax

```wax
#[export = "clamp_low"]
fn clamp_low(x: i32) -> i32 {
    #[likely] if x >=s 0 => i32 {
        x;
    } else {
        0;
    }
}

#[export = "drain"]
fn drain(n: i32) {
    'l: loop {
        #[unlikely] br_if 'l n;
    }
}
```

## Linear Memory

A `memory` declaration reserves linear memory. `load`/`store` methods on it read
and write, with the access width in the method name; a narrow (`load8`/`load16`)
load returns raw bits, so it needs an explicit sign/zero-extending cast.

### Wax

```wax
memory mem: i32 [1];

#[export = "sum_bytes"]
fn sum_bytes(start: i32, end: i32) -> i32 {
    let total: i32 = 0;
    let p: i32 = start;
    while p <u end {
        total += mem.load8(p) as i32_u;   // byte load, zero-extended
        p += 1;
    }
    total;
}
```

## Data Segments with Numeric Values

A data segment's contents can mix string literals with typed numeric runs —
`[type: values]`, packed little-endian — instead of hand-escaping every byte.

### Wax

```wax
memory mem: i32 [1];

// "GIF89a" header, then a 4-lane f32 palette and two i16 dimensions.
data header @ mem[0] =
    "GIF89a"
    ++ [f32: 1.0, 0.5, 0.25, 0.0]
    ++ [i16: 640, 480];
```

## SIMD

`v128` vector operations are method intrinsics with the lane shape baked into the
name (`mul_i32x4`, `add_i32x4`, `extract_lane_i32x4`).

### Wax

```wax
#[export = "madd_i32x4"]
fn madd_i32x4(a: v128, b: v128, c: v128) -> v128 {
    a.mul_i32x4(b).add_i32x4(c);          // a * b + c, four i32 lanes at once
}

#[export = "sum_lanes"]
fn sum_lanes(v: v128) -> i32 {
    v.extract_lane_i32x4(0) + v.extract_lane_i32x4(1)
        + v.extract_lane_i32x4(2) + v.extract_lane_i32x4(3);
}
```

## Stack Switching

A continuation type wraps a function type with `cont`. A coroutine `suspend`s
with a value; a driver `resume`s it, routing the suspended tag to a handler
label that receives the payload and the paused continuation. Note that the
continuation's type changes after a suspend, since resuming it now needs the
reply value.

### Wax

```wax
type task = fn() -> i32;
type k = cont task;
type resumed = fn(i32) -> i32;   // the continuation's type after a suspend
type kr = cont resumed;

tag yield(i32) -> i32;

// A coroutine: yield 10, then return the reply plus one.
fn worker() -> i32 {
    let reply: i32 = suspend yield(10);
    reply + 1;
}

// Run the worker until its first suspend and return the value it yielded.
#[export = "first_yield"]
fn first_yield() -> i32 {
    let c: &?k = k::new(worker);
    let (v, rest) =
        'on_yield: do () -> (i32, &kr) {
            _ = c!.resume() on [yield -> 'on_yield];  // worker returned; drop its result
            return -1;
        };
    _ = rest;            // `rest` could be resumed with a reply to continue the worker
    v;
}
```


<!-- docs/src/correspondence/intro.md -->

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


<!-- docs/src/correspondence/types.md -->

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

Exact references (`&!<t>` / `&?!<t>`, gated on `-X custom-descriptors`) are
explained in the [language guide](../language.md#exact-references).

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

### Structs
```wax,check
type point = { x: i32, y: i32 };
type mutable_point = { x: mut i32, y: mut i32 };
```
Maps to Wasm `(type $point (struct (field i32) (field i32)))`.

### Arrays
```wax,check
type bytes = [i8];
type mutable_bytes = [mut i8];
```
Maps to Wasm `(type $bytes (array i8))`.

### Functions
```wax,check
type binop = fn(i32, i32) -> i32;
```
Maps to Wasm `(type $binop (func (param i32 i32) (result i32)))`.
### Continuations
A continuation type (from the [stack-switching proposal](https://github.com/WebAssembly/stack-switching)) wraps a function type:
```wax,check
type ft = fn(i32) -> i32;
type k = cont ft;
```
Maps to Wasm `(type $k (cont $ft))`. See [Stack Switching Instructions](instructions.md#stack-switching-instructions) for the operations on continuations.

`cont` and `nocont` are reserved heap types (like `func`/`struct`), so the abstract continuation references `&cont`, `&?cont` and `&nocont` are available directly in addition to references to declared continuation types (`&k`, `&?k`). Because these names are reserved, a WebAssembly type literally named `$cont` is renamed (e.g. to `cont_2`) when decompiling to Wax.

### Recursive Types

Wax allows defining recursive reference types using `rec { ... }`.

```wax,check
rec {
    type tree = { value: i32, children: &forest };
    type forest = [&?tree];
}
```

### Supertypes and Finality

Types are final by default. To make a type open (extensible), use the `open` keyword.
To specify a supertype, use `: supertype` before the assignment.

```wax,check
type point = { x: i32, y: i32 };                  // final by default
type open_point = open { x: i32 };                // non-final: extensible
type sub_point : open_point = { x: i32, y: i32 }; // extends open_point
```

A subtype repeats its supertype's fields in order; a leading `..` abbreviates
that repeated prefix (`type sub_point : open_point = { .., y: i32 };`). There is
no Wasm counterpart (every Wasm struct lists all its fields), so `..` is
expanded on the way to Wasm. Decompiling reverses it: when a subtype's leading
fields exactly match (name and type) its supertype's, they are collapsed back to
`..`. A renamed or covariantly-refined inherited field does not match, so it is
kept explicit.

### Custom Descriptors

The [custom-descriptors proposal](https://github.com/WebAssembly/custom-descriptors)
lets a struct carry a *descriptor*: a second struct associated with it (used, for
instance, to model a runtime type or vtable). The described type names its
descriptor with a `descriptor <name>` clause, and the descriptor names what it
describes with a `describes <name>` clause. Both clauses sit between the `open`
marker and the struct body:

```wax,check
rec {
  type obj = descriptor obj_desc { x: i32 };
  type obj_desc = describes obj { };
}
```

Maps to Wasm:

```wat,check
(rec
  (type $obj (descriptor $obj_desc) (struct (field $x i32)))
  (type $obj_desc (describes $obj) (struct)))
```

The two types must satisfy several well-formedness rules, all checked during
validation:

- both must be **structs**, declared in the **same `rec` group**;
- the clauses must be **reciprocal**: if `obj` names `obj_desc` as its
  descriptor, then `obj_desc` must describe `obj`;
- a described type must be declared **before** its descriptor;
- in a subtype hierarchy, if a supertype has a descriptor its subtypes must too
  (with a descriptor that is itself a subtype), and a described type is inherited
  covariantly.


<!-- docs/src/correspondence/instructions.md -->

# Instructions

Wax instructions are expression-oriented.

## Literals

A [character literal](../language.md#characters) is an `i32` constant (its
Unicode code point); a [string literal](../language.md#strings) builds an `i8`
or `i16` array with `array.new_fixed`. An `i8` array holds the raw UTF-8 bytes;
an `i16` array holds the UTF-16 code units (so the string must be valid Unicode).

| Wasm | Wax |
|------|-----|
| `i32.const <code point>` | `'c'` |
| `array.new_fixed $t` (constant elements) | `"..."` or `t # "..."` |

In WAT both forms are written with annotations (`(@char …)` and `(@string …)`),
so they round-trip faithfully through WAT. A Wasm binary keeps only the
underlying `i32.const` / `array.new_fixed`: a character decompiles to a plain
integer, and an `array.new_fixed` is recovered as a string only when its
elements, decoded by the array's element type (UTF-8 for `i8`, UTF-16 for
`i16`), form a reasonable string (valid text, no control characters other
than tab/newline/carriage return); otherwise it stays an
[array literal](#aggregate-instructions).

## Numeric Instructions

Binary and unary operations use standard mathematical operators. Signedness is often explicit in the operator.

| Wasm | Wax |
|------|-----|
| `i32.add` / `i64.add` | `+` |
| `i32.sub` / `i64.sub` | `-` |
| `i32.mul` / `i64.mul` | `*` |
| `i32.div_s` / `i64.div_s` | `/s` |
| `i32.div_u` / `i64.div_u` | `/u` |
| `i32.rem_s` / `i64.rem_s` | `%s` |
| `i32.rem_u` / `i64.rem_u` | `%u` |
| `i32.and` / `i64.and` | `&` |
| `i32.or` / `i64.or` | `\|` |
| `i32.xor` / `i64.xor` | `^` |
| `i32.shl` / `i64.shl` | `<<` |
| `i32.shr_s` / `i64.shr_s` | `>>s` |
| `i32.shr_u` / `i64.shr_u` | `>>u` |
| `i32.eqz` / `i64.eqz` | `!x` (logical not) |

### Floating Point Operations

| Wasm | Wax |
|---|---|
| `f32.add` / `f64.add` | `+` |
| `f32.sub` / `f64.sub` | `-` |
| `f32.mul` / `f64.mul` | `*` |
| `f32.div` / `f64.div` | `/` |
| `f32.abs` ... `f64.sqrt` | `val.abs()`, `val.ceil()`, `val.floor()`, `val.trunc()`, `val.nearest()`, `val.sqrt()` |
| `f32.min` ... `f64.copysign` | `v1.min(v2)`, `v1.max(v2)`, `v1.copysign(v2)` |

### Advanced Integer Operations

| Wasm | Wax |
|---|---|
| `i32.clz` ... `i64.popcnt` | `val.clz()`, `val.ctz()`, `val.popcnt()` |
| `i32.extend8_s` ... `i64.extend16_s` | `val.extend8_s()`, `val.extend16_s()` |
| `i32.rotl` ... `i64.rotr` | `v1.rotl(v2)`, `v1.rotr(v2)` |

### Wide Arithmetic

These 128-bit operations take and return their operands as `(low, high)` pairs
of `i64` values, so each is written as a call returning two results (typically
bound with a multi-value `let`).

| Wasm | Wax |
|---|---|
| `i64.add128` | `i64::add128(a_lo, a_hi, b_lo, b_hi)` |
| `i64.sub128` | `i64::sub128(a_lo, a_hi, b_lo, b_hi)` |
| `i64.mul_wide_s` | `i64::mul_wide_s(a, b)` |
| `i64.mul_wide_u` | `i64::mul_wide_u(a, b)` |



### Conversions

| Wasm | Wax |
|---|---|
| `i32.wrap_i64` | `val as i32` |
| `i64.extend_i32_s` | `val as i64_s` |
| `i64.extend_i32_u` | `val as i64_u` |
| `i32.trunc_f32_s` | `val as i32_s` |
| `f32.convert_i32_s` | `val as f32_s` |
| `f32.demote_f64` | `val as f32` |
| `f64.promote_f32` | `val as f64` |
| `i32.reinterpret_f32` | `val.to_bits()` |
| `f32.reinterpret_i32` | `val.from_bits()` |

## Comparison

| Wasm | Wax |
|------|-----|
| `eq` | `==` |
| `ne` | `!=` |
| `lt_s` / `lt` | `<s` / `<` |
| `lt_u` | `<u` |
| `le_s` / `le` | `<=s` / `<=` |
| `le_u` | `<=u` |
| `gt_s` / `gt` | `>s` / `>` |
| `gt_u` | `>u` |
| `ge_s` / `ge` | `>=s` / `>=` |
| `ge_u` | `>=u` |

On reference operands (any subtype of `&eq`), `==` and `!=` are reference
equality: `a == b` is `ref.eq`, and `a != b` is `ref.eq` followed by `i32.eqz`
(there is no `ref.ne` instruction).

## Variable Instructions

| Wasm | Wax |
|------|-----|
| `local.get $x` | `x` |
| `local.set $x` | `x = val` |
| `local.tee $x` | `x := val` |
| `global.get $g` | `g` |
| `global.set $g` | `g = val` |
| `(local $x t)` | `let x : t` |

When an expression leaves several values on the stack (typically a call to a
[multi-result function](../language.md#variables)) and a run of `local.set`
instructions immediately stores them into locals, the two collapse into a single
multi-binding `let`. A `drop` of one of the results becomes a `_` binding:

```
(call $divmod ...)      let (q, r) = divmod(...);
(local.set $r)
(local.set $q)
```

The number of stores folded is exactly the producer's result arity, so a
`local.set` that consumes a value already on the stack below the call is left as
its own assignment.

A [compound assignment](../language.md#assignment) `x op= val` is shorthand for
`x = x op val`; it lowers to a `local.get`/`global.get` of `x`, the operand, the
binary operator, and a `local.set`/`global.set` back into `x`. The reverse
direction recognises exactly this shape (a `set` of `x` whose value is a binary
operator with `x` as its *left* operand) and reconstructs the compound form
(`x = x + 1` becomes `x += 1`). A comparison, or `x` in the right operand
(`x = 1 - x`), is left as an ordinary assignment.

## Control Instructions

| Wasm | Wax |
|------|-----|
| `block` | `do { ... }` or `{ ... }` |
| `loop` | `loop { ... }` |
| `loop` + leading back-`br` idiom | `while cond { ... }` |
| `loop { if c { block 'l {...}; step; br } }` | `'l: while c : (step) { ... }` (continue-expression) |
| `loop` + trailing back-`br_if` idiom | `loop { ... br_if 'l cond; }` (kept as a plain loop) |
| `if ... else ...` | `if cond { ... } else { ... }` |
| `br $l` | `br 'l` |
| `br_if $l` | `br_if 'l cond` |
| `br_table $l* $ld` | `br_table ['l1, 'l2, else 'ld] val` |
| `br_on_null $l` | `br_on_null 'l val` |
| `br_on_non_null $l` | `br_on_non_null 'l val` |
| `br_on_cast $l $t1 $t2` | `br_on_cast 'l t2 val` |
| `br_on_cast_fail $l $t1 $t2` | `br_on_cast_fail 'l t2 val` |
| `br_on_cast_desc_eq $l $t1 $t2` | `br_on_cast 'l [?]descriptor(d) val` |
| `br_on_cast_desc_eq_fail $l $t1 $t2` | `br_on_cast_fail 'l [?]descriptor(d) val` |
| `return` | `return val` |
| `call $f` | `f(args)` |
| `call_ref $t` | `(val as &?t)(args)` |
| `return_call $f` | `become f(args)` |
| `return_call_ref $t` | `become (val as &?t)(args)` |
| `unreachable` | `unreachable` |
| `nop` | `nop` |
| `select` | `cond ? v1 : v2` |
| `drop` | `_ = val` |

A `drop` becomes an assignment to `_`, an anonymous binding that evaluates its
value and discards it (see [Discarding a value](../language.md#discarding-a-value)).
When the dropped value is a bare numeric expression whose width the Wax syntax
would not otherwise carry, the conversion pins it with a type annotation,
`_: t = val`, so re-reading the Wax does not re-default the value to `i32`/`f64`
and silently change its width. The annotation is emitted only where it is
load-bearing; a value already anchored by a typed sub-expression (a local, a
call) needs none.

The rows above are the raw instructions. Two common *shapes* built from them are
recovered as higher-level constructs on the way back to Wax: a `br_table` in the
conventional dense void-switch shape becomes a [`dispatch`](#dispatch-and-match),
and a `br_on_cast`/`br_on_null` ladder becomes a [`match`](#dispatch-and-match)
(both below).

### Block Labels and Types

Blocks, loops, and ifs can be labeled and typed.
Labels are identifiers starting with `'` followed by a colon.

```wax
'my_block: do { ... }
'my_loop: loop { ... }
```

Block types (signatures) can be specified using `(param) -> result` syntax or a single value type.
If no type is specified, the `do` keyword is optional.

```wax
do (i32) -> i32 { ... }
do i32 { ... }
{ ... }                  ;; equivalent to do { ... }
if cond => (i32) -> i32 { ... } else { ... }
```

A single result type can be **inferred**, so converting from WebAssembly drops
it wherever it is redundant: a `do i32 { ... }` becomes `do { ... }`, an
`if cond => i32 { ... }` loses its `=> i32`, and likewise for `loop`, `try`, and
`try_table`. The type is recovered when reading the Wax back, from the values
reaching the block's exit or from the surrounding context (see
[Type inference](../language.md#blocks)). Parameterized and multi-result block
types are always kept.

### Branch Hints

The [branch-hinting proposal](https://github.com/WebAssembly/branch-hinting)
annotates a conditional branch as likely or unlikely taken. Wax writes the hint
as an attribute on the branch and preserves it on every round-trip (it is stored
in the `metadata.code.branch_hint` custom section; no feature flag is needed):

```wax
#[likely] if cond { ... } else { ... }
#[unlikely] br_if 'l cond
```

Any conditional branch may be hinted: `if`, `br_if`, `br_on_null`,
`br_on_non_null`, `br_on_cast`, and `br_on_cast_fail`. In WAT the same hint is
the `(@metadata.code.branch_hint "\00"|"\01")` annotation preceding the branch
(`"\01"` = likely, `"\00"` = unlikely).

### Dispatch and Match

Two Wax control constructs have no instruction of their own: they are readable
spellings of a lower-level *shape*, so they lower to that shape and are
*recovered* from it on decompilation (both round-trip through the binary). See
the language guide for the surface syntax: [`dispatch`](../language.md#dispatch)
and [`match`](../language.md#match).

`dispatch` is a jump table. It lowers to one nested block per case with a
`br_table` in the innermost block and the case bodies (which fall through) after
their blocks; a `br_table` matching that dense void-switch shape decompiles back
to `dispatch`:

```
(block $big (block $b (block $a           dispatch x ['zero, 'one, else 'big] {
  (br_table $a $b $big (local.get $x)))     'big:  { … }
  … 'one body …) … 'big body …)             'one:  { … }
                                            'zero: { … } }
```

`match` is a multi-way type test. It lowers to a ladder of blocks threading the
scrutinee through `br_on_cast` (and `br_on_null` for a `null` arm), each branch
delivering the narrowed value out to its arm; such a ladder decompiles back to
`match`:

```
(block $default (block $arm_1                match v {
  (block $arm (result (ref $point))            p: &point => { … }
    (br_on_null $arm_1                          null      => { … }
      (br_on_cast $arm eqref (ref $point) …)))  _         => { … } }
  … arm body …) … default …)
```

## Reference Instructions

| Wasm | Wax |
|------|-----|
| `ref.null` | `null` |
| `ref.func $f` | `f` |
| `ref.is_null` | `!val` |
| `ref.as_non_null` | `val!` |
| `ref.i31` | `val as &i31` |
| `i31.get_s` | `val as i32_s` |
| `i31.get_u` | `val as i32_u` |
| `ref.cast` | `val as &type` |
| `ref.test` | `val is &type` |
| `ref.cast (ref (exact $t))` | `val as &!t` |
| `ref.test (ref (exact $t))` | `val is &!t` |
| `ref.cast_desc_eq $t` | `val as descriptor(d)` |
| `ref.cast_desc_eq (ref null …) $t` | `val as ?descriptor(d)` |
| (no instruction) | `val as &k` (`k` a continuation type: a compile-time ascription) |

There is no `ref.cast` (or `ref.test`/`br_on_cast`) to a continuation type: `as` with a continuation target is a compile-time ascription, accepted only when the operand's static type is already a subtype of the target (or the operand is a `null` literal / stack-polymorphic), and it emits nothing — its use is pinning the type immediate of a [`resume` through a supertype signature](#stack-switching-instructions).

A bare function name used as a value, `f` rather than the call `f(args)`, is `ref.func $f`: it produces a reference to the function. This works in a global initializer and anywhere a `&func` reference is expected (for example the callee of an [indirect call](../language.md#indirect-calls)).

These casts can also chain through a forced intermediate, written as a single `as`:

- **`&ref as i32_s`/`as i32_u`** on a reference that is not already `&i31` (e.g. an `&any` or `&eq`) inserts a `ref.cast (ref i31)` before the `i31.get`, so it covers both `i31.get_s` and `ref.cast (ref i31)` + `i31.get_s`.
- **`&ref as i64_s`/`as i64_u`** widens that further: the `i31.get` (with the `ref.cast` above as needed) is followed by `i64.extend_i32_s`/`_u`.
- **`i64 as &i31`** wraps to `i32` (`i32.wrap_i64`) before `ref.i31`.
- **`extern_val as &T`** for an `any`-hierarchy `T` (e.g. a struct type) inserts `any.convert_extern` before the `ref.cast (ref T)`; likewise an `any`-hierarchy value `as &extern` uses `extern.convert_any`.
- **`i32_val as &extern`** boxes the `i32` with `ref.i31` before `extern.convert_any`.

## Aggregate Instructions

A struct or array literal takes an optional type prefix (`{t| … }` for a
struct, `[t| … ]` for an array), but it is omitted whenever the literal's type
can be inferred from context (an assignment, a return, a call argument), which
is the common case shown below. Write the prefix only when the type is
ambiguous. The `{descriptor(d)| … }` forms are different: `descriptor(d)`
supplies the runtime descriptor and is part of the construction, not a prefix
that can be dropped.

| Wasm | Wax |
|------|-----|
| `struct.new $t` | `{ field: val, ... }` |
| `struct.new_default $t` | `{ .. }` |
| `struct.new_desc $t` | `{descriptor(d)\| field: val, ... }` |
| `struct.new_default_desc $t` | `{descriptor(d)\| .. }` |
| `struct.get $t $f` | `val.field` |
| `struct.set $t $f` | `val.field = new_val` |
| `ref.get_desc $t` | `val.descriptor` |
| `array.new $t` | `[ val; len ]` |
| `array.new_default $t` | `[ ..; len ]` |
| `array.new_fixed $t` | `[ val, ... ]` |
| `array.new_data $t $d` | `[ d @ offset; count ]` |
| `array.new_elem $t $e` | `[ e @ offset; count ]` |
| `array.init_data $t $d` | `arr.init(d, dest, src, count)` |
| `array.init_elem $t $e` | `arr.init(e, dest, src, count)` |
| `array.fill $t` | `arr.fill(idx, val, count)` |
| `array.copy $t1 $t2` | `arr.copy(idx, src_arr, src_idx, count)` |
| `array.get $t` | `arr[idx]` |
| `array.get_s $t` | `arr[idx] as i32_s` |
| `array.get_u $t` | `arr[idx] as i32_u` |
| `array.set $t` | `arr[idx] = val` |
| `array.len` | `arr.length()` |

A packed (`i8`/`i16`) struct field or array element read sign- or zero-extends to `i32` via the `as i32_s`/`as i32_u` cast, as shown above (`struct.get_s`/`_u`, `array.get_s`/`_u`). Widening straight to `i64` (`val.field as i64_s` or `arr[idx] as i64_u`) emits the packed read followed by `i64.extend_i32_s`/`_u`.

## SIMD (Vector) Instructions

`v128` vector operations are written as method intrinsics with the lane shape baked into the name. The Wax name is the WebAssembly mnemonic with the leading shape moved to the end: `i32x4.add` becomes `add_i32x4`, `f32x4.sqrt` becomes `sqrt_f32x4`, and the whole-vector `v128.and` becomes `and_v128`. Signed/unsigned variants keep the `_s`/`_u` (`min_s_i8x16`, `extract_lane_u_i8x16`). The constant lane immediates of the value-receiver operations (lane indices, shuffle indices) come first in the argument list, before any remaining stack operands; the lane index of a memory lane access is instead the labelled `lane:` argument (see the loads and stores below).

Lanewise unary and binary operations (the receiver is the first operand):

| Wasm | Wax |
|------|-----|
| `i32x4.add` | `a.add_i32x4(b)` |
| `f32x4.mul` | `a.mul_f32x4(b)` |
| `i8x16.min_s` / `i8x16.min_u` | `a.min_s_i8x16(b)` / `a.min_u_i8x16(b)` |
| `i16x8.lt_u` | `a.lt_u_i16x8(b)` |
| `i32x4.neg` | `v.neg_i32x4()` |
| `f64x2.sqrt` | `v.sqrt_f64x2()` |
| `i8x16.narrow_i16x8_s` | `a.narrow_i16x8_s_i8x16(b)` |
| `f32x4.convert_i32x4_s` | `v.convert_i32x4_s_f32x4()` |

Whole-vector bitwise operations, bit selection (a free function):

| Wasm | Wax |
|------|-----|
| `v128.and` / `or` / `xor` / `andnot` | `a.and_v128(b)`, `a.or_v128(b)`, `a.xor_v128(b)`, `a.andnot_v128(b)` |
| `v128.not` | `v.not_v128()` |
| `v128.bitselect` | `v128::bitselect(a, b, mask)` |

Splat, lane access, and shuffle:

| Wasm | Wax |
|------|-----|
| `i32x4.splat` | `x.splat_i32x4()` |
| `i32x4.extract_lane` | `v.extract_lane_i32x4(lane)` |
| `i8x16.extract_lane_u` | `v.extract_lane_u_i8x16(lane)` |
| `i32x4.replace_lane` | `v.replace_lane_i32x4(lane, x)` |
| `i8x16.shuffle` | `a.shuffle_i8x16(l0, ..., l15, b)` |

Shifts, tests, and bitmask:

| Wasm | Wax |
|------|-----|
| `i16x8.shl` | `v.shl_i16x8(n)` |
| `i32x4.shr_s` / `i32x4.shr_u` | `v.shr_s_i32x4(n)` / `v.shr_u_i32x4(n)` |
| `v128.any_true` | `v.any_true_v128()` |
| `i32x4.all_true` | `v.all_true_i32x4()` |
| `i8x16.bitmask` | `v.bitmask_i8x16()` |

Constants are `v128::` free functions (one argument per lane: 16, 8, 4, or 2). `v128.const` is a constant expression, so it may initialise a global:

| Wasm | Wax |
|------|-----|
| `v128.const i32x4 1 2 3 4` | `v128::i32x4(1, 2, 3, 4)` |
| `v128.const f32x4 1.5 2.5 3.5 4.5` | `v128::f32x4(1.5, 2.5, 3.5, 4.5)` |
| `v128.const i8x16 0 1 ... 15` | `v128::i8x16(0, 1, ..., 15)` |

Memory loads and stores are methods on a [memory](module_fields.md#memories), like the scalar [memory accesses](#memory-access) (the optional labelled `offset:`/`align:` arguments work the same way): the `v128.` mnemonic prefix is dropped and the access shape stays in the name, `_s`/`_u` included; the full-width pair takes the family letter, `loadv128`/`storev128` (extending the `loadf32` convention). The lane index of a lane access is the labelled `lane:` argument, mandatory and in any order with `offset:`/`align:`:

| Wasm | Wax |
|------|-----|
| `v128.load` | `m.loadv128(p)` |
| `v128.store` | `m.storev128(p, v)` |
| `v128.load8x8_s` (and `16x4`/`32x2`, `_s`/`_u`) | `m.load8x8_s(p)` |
| `v128.load32_zero` (and `64_zero`) | `m.load32_zero(p)` |
| `v128.load8_splat` (and `16`/`32`/`64`) | `m.load8_splat(p)` |
| `v128.load8_lane` (and `16`/`32`/`64`) | `m.load8_lane(p, v, lane: l)` |
| `v128.store8_lane` (and `16`/`32`/`64`) | `m.store8_lane(p, v, lane: l)` |

Relaxed-SIMD operations follow the same scheme:

| Wasm | Wax |
|------|-----|
| `f32x4.relaxed_madd` | `a.relaxed_madd_f32x4(b, c)` |
| `i8x16.relaxed_swizzle` | `a.relaxed_swizzle_i8x16(b)` |

No intrinsic can clash with a module entity name: the free-function intrinsics are written as `v128::`/`i64::` qualified paths and every other is a method on a receiver, so a function may freely be named e.g. `v128_bitselect` without any renaming.

## Memory Access

Loads and stores are method calls on a [memory](module_fields.md#memories). The method name carries the access width; the value's signedness (for narrow loads) and its `i32`/`i64` type are expressed with the surrounding `as iN_s`/`as iN_u` cast, mirroring packed array access.

| Wasm | Wax |
|------|-----|
| `i32.load` | `m.load32(p)` |
| `i64.load` | `m.load64(p)` |
| `f32.load` / `f64.load` | `m.loadf32(p)` / `m.loadf64(p)` |
| `i32.load8_s` | `m.load8(p) as i32_s` |
| `i32.load16_u` | `m.load16(p) as i32_u` |
| `i64.load32_s` | `m.load32(p) as i64_s` |
| `i64.load8_s` | `m.load8(p) as i64_s` |
| `i64.load16_u` | `m.load16(p) as i64_u` |
| `i32.store` (`v: i32`) or `i64.store32` (`v: i64`) | `m.store32(p, v)` |
| `i32.store16` or `i64.store16` (by `v`'s type) | `m.store16(p, v)` |
| `i64.store` / `f64.store` | `m.store64(p, v)` / `m.storef64(p, v)` |

A bare narrow load (`m.load8(p)` with no cast) defaults to unsigned `i32`, like `array.get_u`. The store value's `i32`/`i64` type is inferred from the operand.

The `offset` and `align` of the access (both constant integers) are optional labelled arguments, written after the operands in either order:

```wax
m.load32(p);                        // i32.load
m.load32(p, offset: 16);            // i32.load offset=16
m.load32(p, offset: 16, align: 1);  // i32.load offset=16 align=1
m.load32(p, align: 1);              // i32.load align=1
```

The alignment defaults to the access's natural alignment and is only printed when it differs; the offset defaults to `0` and is only printed when non-zero.

The remaining memory operations are also methods on the memory (a data segment is named directly, not as a value):

| Wasm | Wax |
|------|-----|
| `memory.size` | `m.size()` |
| `memory.grow` | `m.grow(n)` |
| `memory.fill` | `m.fill(dest, val, len)` |
| `memory.copy` (within `m`) | `m.copy(dest, src, len)` |
| `memory.copy m m2` (copy from `m2` into `m`) | `m.copy(m2, dest, src, len)` |
| `memory.init seg` | `m.init(seg, dest, src, len)` |
| `data.drop seg` | `seg.drop()` |

### Atomics

Atomic accesses (the threads proposal) are methods on a memory, following the scalar-access naming convention: the access width is in the method name (`atomic_load16`, `atomic_rmw_add8`), the `i32`/`i64` value type comes from the operand and result types, and a narrow load is resolved by an `as iN_u` cast. The narrow accesses are the zero-extending `_u` forms, the only kind that exists, so no suffix or cast signedness choice arises (`as iN_s` on a narrow atomic load is rejected; `atomic_load32(p) as i64_s` has no fused form and compiles as `i32.atomic.load` then `i64.extend_i32_s`). They take the same labelled `offset:` argument as the other accesses; an `align:` argument is accepted but must be exactly the natural alignment (the access width from the name), which is also the default. `atomic.fence` has no memory operand and is the [`atomic::fence()`](language.md#qualified-intrinsics) intrinsic.

| Wasm | Wax |
|---|---|
| `i32.atomic.load` | `m.atomic_load32(p)` |
| `i64.atomic.load` | `m.atomic_load64(p)` |
| `i32.atomic.load8_u` | `m.atomic_load8(p) as i32_u` |
| `i64.atomic.load32_u` | `m.atomic_load32(p) as i64_u` |
| `i32.atomic.store` (`v: i32`) or `i64.atomic.store32` (`v: i64`) | `m.atomic_store32(p, v)` |
| `i64.atomic.store8` (`v: i64`) | `m.atomic_store8(p, v)` |
| `i32.atomic.rmw.add` (`v: i32`) | `m.atomic_rmw_add32(p, v)` |
| `i64.atomic.rmw16.add_u` (`v: i64`) | `m.atomic_rmw_add16(p, v)` |
| `i32.atomic.rmw.cmpxchg` | `m.atomic_rmw_cmpxchg32(p, expected, replacement)` |
| `memory.atomic.notify` | `m.atomic_notify(p, count)` |
| `memory.atomic.wait32` | `m.atomic_wait32(p, expected, timeout)` |
| `atomic.fence` | `atomic::fence()` |

## Table Access

A [table](module_fields.md#tables) is indexed like an array, and an indirect call is written as a call through a table slot cast to the callee's function type.

| Wasm | Wax |
|------|-----|
| `table.get $t` | `t[i]` |
| `table.set $t` | `t[i] = v` |
| `call_indirect $t (type $ft)` | `(t[i] as &?ft)(args)` |
| `call_indirect $t (result i32)` | `(t[i] as &?fn() -> i32)(args)` |
| `return_call_indirect $t (type $ft)` | `return (t[i] as &?ft)(args)` |

`call_indirect` is reconstructed from this pattern on conversion to WAT/Wasm, so it round-trips. The cast target names the callee's function type, a defined type (`ft`) or an inline one written `fn(params) -> results` (used when the WAT type is anonymous), and matches the table's element type: for a `funcref` table (the usual case) it is the nullable `&?ft`, as shown. When the element type is already a non-null `&ft`, the cast may be omitted (`t[i](args)`).

The other table operations are methods on the table (an element segment is named directly):

| Wasm | Wax |
|------|-----|
| `table.size` | `t.size()` |
| `table.grow` | `t.grow(val, n)` |
| `table.fill` | `t.fill(dest, val, len)` |
| `table.copy` (within `t`) | `t.copy(dest, src, len)` |
| `table.copy t t2` (copy from `t2` into `t`) | `t.copy(t2, dest, src, len)` |
| `table.init seg` | `t.init(seg, dest, src, len)` |
| `elem.drop seg` | `seg.drop()` |

A GC array can also be filled from a segment with `arr.init(seg, dest, src, len)` (`array.init_data`/`array.init_elem`, selected by the array's element type), the segment-from-array counterpart of [`array.new_data`/`array.new_elem`](#aggregate-instructions).

## Exception Instructions

| Wasm | Wax |
|------|-----|
| `throw $tag` | `throw tag()` (no payload), `throw tag(x)` (one), `throw tag(x, y)` (several) |
| `throw_ref` | `throw_ref` |
| `try_table ... catch $tag $l ...` | `try { ... } catch [ tag -> 'l, ... ]` |
| `try_table ... catch_ref $tag $l ...` | `try { ... } catch [ tag & -> 'l, ... ]` |
| `try_table ... catch_all $l ...` | `try { ... } catch [ _ -> 'l, ... ]` |
| `try_table ... catch_all_ref $l ...` | `try { ... } catch [ _ & -> 'l, ... ]` |
| `try_table` + block ladder | `try { ... } catch { tag => { ... } tag & => { ... } _ => { ... } }` |
| `try ... catch $tag ...` | `try_legacy { ... } catch { tag => { ... } ... }` |
| `try ... catch_all ...` | `try_legacy { ... } catch { _ => { ... } }` |

Both `try` forms compile to WebAssembly's `try_table` instruction (the current standard): the bracket form is the raw instruction (each clause branches to a label), and the braced structured form adds one block per arm around it — each catch clause branches to its arm's block, the arm bodies are the trailing code between the block ends (so an arm's completion falls into the next arm), and the body's completion escapes past all arms with a single branch carrying the try's value. The decompiler recovers the structured form from exactly that ladder shape (a label on the try is the join block), falling back to the bracket form for any other use of `try_table`. `try_legacy` compiles to the older `try`/`catch` instructions (deprecated but still supported for compatibility), and legacy-instruction modules decompile to it.

## Stack Switching Instructions

These correspond to the WebAssembly [stack-switching proposal](https://github.com/WebAssembly/stack-switching). A continuation type is declared with `type k = cont ft;` (see [Types](types.md)); `<k>` and `<tag>` below are the names of a continuation type and a tag respectively.

The resume family and `switch` are methods on the continuation reference `c`; `cont.new` and `cont.bind` are the `T::new` / `T::bind` constructors of the declared continuation type (the `T::` namespace constructs a `&T`). The type immediates are not written: the `$k` of `resume`/`resume_throw`/`resume_throw_ref`/`switch`, and the *source* type of `bind`, are inferred from the static type of the continuation expression, exactly as `call_ref`'s type immediate comes from the callee's — so the receiver must have a *declared* continuation type (an abstract `&cont` is rejected; a cast can never narrow a continuation, so give the value its precise type where it is introduced). An identity/upcast ascription `(c as &k0).resume(x)` selects the supertype's immediate (`resume $k0`) and emits no instruction; decompilation inserts exactly this ascription when an instruction's type immediate is a strict supertype of its continuation operand's own type, so the immediate survives the round trip.

| Wasm | Wax |
|------|-----|
| `cont.new $k` | `k::new(func)` |
| `cont.bind $k1 $k2` | `k2::bind(args, cont)` |
| `suspend $tag` | `suspend tag(args)` |
| `resume $k` | `c.resume(args)` |
| `resume $k (on $tag $l) ...` | `c.resume(args) on [tag -> 'l, ...]` |
| `resume $k (on $tag switch) ...` | `c.resume(args) on [tag -> switch, ...]` |
| `resume_throw $k $tag ...` | `c.resume_throw(tag(payload)) on [...]` |
| `resume_throw_ref $k ...` | `c.resume_throw_ref(exn) on [...]` |
| `switch $k $tag` | `c.switch(args, tag: tag)` |

Operands compile in WebAssembly stack order: for continuations — as for `call_ref` — that puts the receiver *last*, so `c.resume(x)` evaluates `x` before `c` even though `c` is written first (this diverges from receiver-first methods like `arr.fill`, whose instruction takes the receiver first on the stack). The handler list of a postfix `on [...]` clause mirrors the `try ... catch [...]` syntax — a keyword-led handler bracket after the guarded operation: `tag -> 'l` is an `(on $tag $l)` clause and `tag -> switch` an `(on $tag switch)` clause; the clause is omitted when empty. `resume_throw` raises its tag applied to the payload, `tag(payload)`, exactly as `throw tag(payload)` spells it, and `switch`'s enabling tag is the required labelled `tag:` immediate.

Tags used with `suspend`/`resume` may have result types (unlike exception tags); see [Tags](module_fields.md#tags). When a function reference is passed to `T::new` for a continuation whose function type belongs to a recursion group, declare the function with an explicit type (`fn f: ft (...) { ... }`) so its type matches the continuation's.


<!-- docs/src/correspondence/module_fields.md -->

# Module Fields

Wax modules are defined by a sequence of top-level fields: types, functions, globals, memories, tables, and tags.

## Module Name

A `#![module = "..."]` inner attribute at the top of the file names the module.
It maps to the WebAssembly module name, the symbolic name stored in the module
subsection of the `name` custom section, written `$name` in WAT:

```wax,check
#![module = "my_module"]
```

corresponds to the WAT

```wat
(module $my_module …)
```

A module may carry at most one name, and it must not appear inside a conditional
(`#[if]`/`#[else]`): the name applies in every configuration. See also
[Module Name](../language.md#module-name) in the language guide.

## Feature Declarations

A `#![feature = "..."]` inner attribute declares an optional proposal the
module uses (see [Features](../language.md#features) in the language guide).
It maps to a module-level `(@feature "...")` annotation in WAT:

```wax,check
#![feature = "custom-descriptors"]
```

corresponds to the WAT

```wat
(@feature "custom-descriptors")
```

Both are read on input and emitted on output, so the declaration survives a
Wax/WAT round-trip. In the binary format, each declared feature becomes a
`+name` entry of the conventional `target_features` custom section
([tool-conventions](https://github.com/WebAssembly/tool-conventions/blob/main/Linking.md#target-features-section)):

```text
(@custom "target_features" "\01+\12custom-descriptors")
```

Other producers' entries in that section (standard names like `+simd128`, or
`-` entries) are preserved verbatim through a binary round-trip but do not
become attributes. Decompiling a binary restores the declarations from the
union of the section's recognised `+` entries and the gated encodings the
module actually uses (a descriptor type, an exact reference, a compact import
section, ...), so even a binary whose producer wrote no section decompiles to
a module that recompiles standalone.

## Types

Types are defined using `type` for single definitions or `rec { ... }` for mutually recursive types.

### Simple Types

```wax,check
type point = { x: i32, y: i32 };
type bytes = [i8];
type callback = fn(i32) -> i32;
```

### Recursive Types

Use `rec` when types reference each other:

```wax,check
rec {
    type list = { head: i32, tail: &?node };
    type node = { rest: &list };
}
```

### Supertypes and Finality

Types are final (non-extensible) by default. Use `open` to allow subtypes:

```wax,check
type shape = open { x: i32, y: i32 };
type circle : shape = { x: i32, y: i32, radius: i32 };
```

Maps to:

```wat,check
(type $shape (sub (struct (field $x i32) (field $y i32))))
(type $circle (sub $shape (struct (field $x i32) (field $y i32) (field $radius i32))))
```

## Functions

### Definition

```wax
fn name(param: type, ...) -> return_type {
    body
}
```

Functions without a return type:

```wax,check
fn log_value(x: i32) {
    // no return
}
```

### Function Signatures (Declarations)

Declare a function signature without a body (used with imports):

```wax
fn external_function(x: i32) -> i32;
```

An imported function can be marked [exact](../language.md#exact-references) so
that referencing it yields an exact reference: `fn g: !ft;` for a named type, or
`fn h!(x: i32) -> i64;` for an inline signature. This maps to the WAT
`(func (exact <type>))` import descriptor.

### Block Type Annotation

Functions can have a block type on the body:

```wax
fn example() -> i32 'label: {
    // body can use 'label
}
```

## Globals

### Immutable Globals

```wax,check
const PI: f64 = 3.14159;
const MAX_SIZE: i32 = 1024;
```

### Mutable Globals

```wax,check
let counter: i32 = 0;
let state: &?any = null;
```

### Imported Globals

```wax,check
import "env" {
    const base: i32;
    let counter: i32;
}
```

## Memories

A memory is declared with `memory`, followed by its address type (`i32` or `i64`) and, optionally, its limits as `[min]` or `[min, max]` (in pages of 64 KiB):

```wax,check
memory mem0: i32 [1, 1000];
memory mem1: i64 [2];
memory mem2: i32;
```

Maps to:

```wat
(memory $mem0 i32 1 1000)
(memory $mem1 i64 2)
(memory $mem2 i32 ...)
```

When the limits are omitted, the minimum size is derived from the extent of the memory's data segments (using their literal offsets).

A custom page size is written with a `pagesize` clause after the limits, mapping to the WAT `(pagesize N)` form. The page size must be `1` or `65536` (the default), and the limits are counted in pages of that size:

```wax,check
memory small: i32 [4096] pagesize 1;
```

```wat,check
(memory $small 4096 (pagesize 1))
```

A `shared` clause (the threads proposal) marks the memory shared; it must have a maximum size:

```wax,check
memory pool: i32 [1, 16] shared;
```

```wat,check
(memory $pool 1 16 shared)
```

Loads and stores use method-call syntax on the memory, with the value's width in the method name and its signedness expressed by the surrounding [`as iN_s`/`as iN_u` cast](instructions.md#memory-access), the same convention as packed array access:

```wax
let x: i32 = mem0.load32(p);
let b: i32 = mem0.load8(p) as i32_u;
mem0.store16(p, v);
mem0.store32(p, v, offset: 16, align: 1);
```

See [Memory Access](instructions.md#memory-access) for the full instruction mapping.

### Data Segments

A memory declaration may carry active data segments in a block, placed at a constant offset:

```wax,check
memory mem1: i64 {
    data _ @ [0x1000] = "hello world";
    data greeting @ [0x2000] = "hi";
}
```

Top-level `data` defines a passive segment, or an active segment for a named memory:

```wax
data seg = "raw\x00bytes";
data init @ mem0 [0] = "hello";
```

Data bytes are ordinary [string literals](../language.md#strings); escapes such as `\x41` and `\x00` (two hex digits) decode to raw bytes.

A segment's contents may also concatenate (with `++`) strings and **typed numeric runs** — `[type: values]`, whose element type is stated once and whose values are packed little-endian. This is the WebAssembly *numeric values* text-format extension, and it round-trips through WAT:

```wax
data pixels = "hdr" ++ [f32: 0.2, 0.3, 0.4] ++ [i16: -1, -2, -3] ++ [i8: 1, 2, 3, 4];
```

The scalar element types are `i8`, `i16`, `i32`, `i64`, `f32`, and `f64`; the values (including `nan`/`inf`) are ordinary literals. A `v128` run holds lane groups written `shape(lanes)`, e.g. `[v128: i32x4(1, 2, 3, 4), f64x2(1.0, 2.0)]`. The bytes are the same as if the values were written out as an escaped string.

## Tables

A table is declared with `table`, followed by its element [reference type](types.md) and, optionally, its limits as `[min]` or `[min, max]`:

```wax,check
table funcs: &?func [1, 10];
table objs: &?any [0];
```

Maps to:

```wat,check
(table $funcs 1 10 funcref)
(table $objs 0 anyref)
```

A table element is read and written with index syntax, like an array: `tab[i]` is `table.get` and `tab[i] = v` is `table.set`:

```wax
let f: &?func = funcs[i];
funcs[i] = g;
```

There is no dedicated `call_indirect` syntax: it is written as a call through a table slot, narrowing the slot to the callee's [function type](#functions) with a cast. WAT `call_indirect` round-trips through this form:

```wax
type cmp = fn(i32, i32) -> i32;

(funcs[i] as &cmp)(x, y)        // call_indirect $funcs (type $cmp)
```

The other table-management instructions have method syntax too: `t.size()`,
`t.grow(init, n)`, `t.fill(dst, val, n)`, `t.copy(dst, src, n)`,
`t.init(seg, dst, src, n)`, and `seg.drop()` on an element segment (see
[Instructions](instructions.md)).

### Element Segments

An element segment is declared with `elem`, its element reference type, and a bracketed list of constant element expressions. A bare `elem` is passive; `@ table[offset]` makes it an active segment that initializes a table:

```wax
elem dispatch: &?func = [handler_a, handler_b, handler_c];   // passive
elem init: &?func @ funcs[0] = [handler_a, handler_b];       // active
elem nums: &?i31 = [1 as &i31, 2 as &i31];                   // expression form
```

A passive element segment can initialize a GC array with [`array.new_elem`](instructions.md#aggregate-instructions), written with the same `[t| seg @ off; count]` syntax as `array.new_data`; which one applies is determined by the array's element type (a reference element selects the element segment):

```wax
type handlers = [&?func];

let hs: &handlers = [handlers| dispatch @ 0; 3];
```

## Tags

Tags define exception types for structured exception handling.

### Definition

```wax,check
type string = [mut i8];

tag my_error(code: i32);
tag empty_error();
tag multi_arg(a: i32, b: &string);
```

Maps to:

```wat
(tag $my_error (param i32))
(tag $empty_error)
(tag $multi_arg (param i32) (param (ref $string)))
```

A tag may also declare a result type, in which case it is used as a suspension tag for [stack switching](instructions.md#stack-switching-instructions) rather than for exceptions:

```wax,check
tag yield(value: i32) -> i32;
```

### Imported Tags

```wax,check
import "env" tag js_error(&?extern);
```

## Attributes

Attributes modify module fields. They use the syntax `#[name = value]`, or `#[name]` when no value is needed, and appear before the field they modify.

### Export Attribute

Export a field with a given name:

```wax,check
#[export = "add"]
fn add(x: i32, y: i32) -> i32 { x + y; }

#[export = "PI"]
const PI: f64 = 3.14159;

#[export = "my_error"]
tag my_error(code: i32);
```

The name is optional: a bare `#[export]` exports the field under its own Wax name.

```wax,check
#[export]
fn add(x: i32, y: i32) -> i32 { x + y; }
```

Multiple exports can share the same function:

```wax,check
#[export = "add"]
#[export = "plus"]
fn add(x: i32, y: i32) -> i32 { x + y; }
```

### Start Attribute

Mark a function to run at module instantiation. It takes no value and the
function must have no parameters and no results (it maps to the Wasm `start`
field):

```wax,check
#[start]
fn init() {
    // initialization code
}
```

An imported function can also be the start function, running host-provided
initialization at instantiation:

```wax,check
import "env" #[start] fn init();
```

## Imports

Import fields from a host module with an `import "module" { … }` block; a lone
import can use the one-line `import "module" <declaration>;` form. Each entry is
imported under its own Wax name, unless a name-only `#[import = "name"]`
overrides that.

```wax,check
import "env" {
    fn log(msg: i32);
    const memory_base: i32;
    #[import = "js_error"]
    tag error(code: i32);
}

import "env" fn trace(msg: i32);
```

### Combined Import and Export

A field can be both imported and re-exported by adding `#[export]` to it:

```wax,check
import "env" #[export = "value"] const value: i32;
```

## Conditional Annotations

Both formats can guard module fields by a condition that a downstream preprocessor evaluates. Wax uses `#[if(...)] { ... }` / `#[else] { ... }`, with the braces required around each branch; WAT uses the annotation form `(@if <cond> (@then ...) (@else ...))`.

```wax,check
#[if(ocaml_version >= (5, 1, 0))]
{
    const size: i32 = 16;
}
#[else]
{
    const size: i32 = 20;
}
```

```wat
(@if (>= $ocaml_version (5 1 0))
  (@then (global $size i32 (i32.const 16)))
  (@else (global $size i32 (i32.const 20))))
```

The conditions are equivalent; note the surface differences: Wax variables are bare (`ocaml_version`) while WAT variables are `$`-prefixed; Wax versions are tuples `(5, 1, 0)` while WAT writes them `(5 1 0)`; Wax combines conditions with `all`/`any`/`not`, WAT with `and`/`or`/`not`.

The conditions are preserved, not evaluated. Type checking (`--validate`) explores each reachable combination independently (see the [Language Guide](../language.md#conditional-compilation)). The two forms convert to each other, so a conditional written in Wax survives a round-trip through WAT and back.

## Module Structure

A typical Wax module follows this structure:

```wax,check
// 1. Type definitions
type point = { x: i32, y: i32 };
type callback = fn(i32) -> i32;

// 2. Imported globals and functions
import "env" {
    fn log(value: i32);
    const base: i32;
}

// 3. Tags
tag my_error(code: i32);

// 4. Module globals
const FACTOR: i32 = 100;
let counter: i32 = 0;

// 5. Internal functions
fn helper(x: i32) -> i32 {
    x * FACTOR;
}

// 6. Exported functions
#[export = "compute"]
fn compute(x: i32) -> i32 {
    counter = counter + 1;
    log(counter);
    helper(x + base);
}
```

This order is conventional but not required; Wax allows fields in any order.


<!-- docs/src/cli.md -->

# CLI Reference

The `wax` binary is the primary interface for the Wax toolchain. It supports conversion between Wax, WebAssembly Text (WAT), and WebAssembly Binary (Wasm) formats.

## Usage

```sh
wax [OPTIONS] [INPUT]         # convert (the default command)
wax convert [OPTIONS] [INPUT] # the same, named explicitly
wax format [OPTIONS] FILE…    # reformat files
wax check [OPTIONS] FILE…     # validate files
wax lsp                       # run the language server (over stdin/stdout)
```

By default `wax` converts between formats; this command is also available under
its explicit name, `wax convert` (useful when an input filename could be
mistaken for a subcommand). The `format` subcommand reformats files (see
[Formatting](#formatting)), `check` validates them (see [Checking](#checking)),
and `lsp` starts a Language Server Protocol server for editors (see [Language
server](#language-server)).

## Positional Arguments

- `[INPUT]`: Source file to convert/format. Supported extensions: `.wax`, `.wat`, `.wasm`.
    - If omitted, `wax` reads from `stdin`.

## Options

- **`-o`**, **`--output`** *FILE*
    - Output file. Writes to `stdout` if not specified.

- **`-f`**, **`--format`**, **`--output-format`** *FORMAT*
    - Specify the output format.
    - Values: `wax`, `wat`, `wasm`.
    - Default: `wax` (if not auto-detected from output filename).

- **`-i`**, **`--input-format`** *FORMAT*
    - Specify the input format.
    - Values: `wax`, `wat`, `wasm`.
    - Default: Auto-detected from input filename, or `wax` if reading from stdin.

- **`-v`**, **`--validate`**
    - Force validation, and additionally report unused locals.
    - For Wax: Runs type checking.
    - For Wasm Text: Runs well-formedness checks.
    - A text input (Wax/WAT) is **validated by default before it is converted to a different format**: the conversion and lowering passes trust that their input is well-formed, so a malformed module is rejected up front rather than reaching them. A same-format conversion (`wat` → `wat`, `wax` → `wax`) only re-prints and is *not* validated by default; a Wasm *binary* input is trusted and *not* validated. `--validate` forces validation in every case.
    - Reports a warning for any local that is declared but never read: a Wax `let` binding, or a Wasm Text `(local …)`. This reporting is only enabled by `--validate` (the default validation above does not turn it on). Prefix the name with `_` (e.g. `let _x = …`, `(local $_x i32)`) to mark it intentionally unused and silence the warning; function parameters are never reported. This `unused-local` warning can be silenced, kept, or promoted to an error with [`-W`](#options) (e.g. `-W unused-local=error`).
    - For input containing conditional annotations (`#[if]` / `(@if ...)`), every reachable combination of conditions is checked independently, and each error is reported with the assumption (`reachable when ...`) under which it occurs.

- **`-s`**, **`--strict-validate`**
    - Perform strict reference validation for Wasm Text input (overrides the default relaxed validation). Wasm *binary* input is always validated strictly, regardless of this flag. When compiling Wax or Wasm Text to a binary, functions referenced by `ref.func` only inside a function body are automatically declared (via a declarative element segment), so the output passes strict validation.

- **`-D`** *NAME[=VALUE]*, **`--define`** *NAME[=VALUE]*
    - Set a conditional-compilation variable, specializing `#[if(...)]` (Wax) and
      `(@if ...)` (WAT) annotations. A fully determined conditional is removed
      (its surviving branch is spliced in) and a partially determined one is kept
      with its condition simplified (the set variables substituted, the rest
      left). Comments inside a removed branch are dropped.
    - The value kind is inferred: a bare *NAME* (or `NAME=true` / `NAME=false`)
      sets a boolean; `NAME=N.N.N` (three integers) sets a version; any other
      `NAME=VALUE` sets a string.
    - Repeatable, to set several variables. Has no effect on Wasm binary input
      (which carries no conditionals).

- **`-X`** *NAME[=on|off]*, **`--feature`** *NAME[=on|off]*
    - Enable (or disable) an optional WebAssembly proposal, off by default.
      Bare *NAME* or `NAME=on`/`true`/`yes` enables it; `NAME=off`/`false`/`no`
      disables it. Repeatable. Known features:
        - `custom-descriptors`: exact reference types (`&!t`), `descriptor`/`describes`
          struct clauses, and the descriptor instructions. Without it these
          constructs are rejected during validation.
        - `compact-import-section`: write same-module imports under one module
          name in the binary import section. What the flag enables depends on the
          input, because the text form is authoritative for import layout. From a
          text input (Wax or WAT), a `import "m" { … }` block / `(import "m"
          (item …) …)` group is lowered to a compact entry — a name-only group
          sharing one type when the items' types all match, else one type per
          item; a Wax block of one item flattens to a plain import, and imports
          the source left *separate* are never merged. From a WASM binary — which
          has no authorial text layout — the flag instead coalesces runs of
          consecutive same-module plain imports (the "compress this binary"
          mode). Groups written explicitly, or already present in a binary, are
          preserved through WAT↔WAT and WASM↔WASM round-trips on their own, no
          flag needed.
    - A module can also declare the features it uses itself, with a
      `#![feature = "NAME"]` inner attribute (WAT: a module-level
      `(@feature "NAME")` annotation); see
      [Features](./language.md#features). The declared and enabled sets are
      unioned. The one exception is a conflict: an explicit `-X NAME=off`
      against a module that declares *NAME* is an error, reported at the
      attribute, since the file states a fact and the flag states a policy and
      neither silently wins.
    - A binary persists the declarations as `+NAME` entries of the
      conventional `target_features` custom section, one entry per declared
      feature; other producers' entries there are preserved verbatim and not
      interpreted. Decompiling a binary restores the attributes from the
      union of those entries and the gated encodings the module actually
      uses.

- <a id="warnings"></a>**`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL*
    - Set the reporting level of a warning produced during validation.
    - *NAME* is a single warning, a group, or `all`:
        - `unused-local` (group `unused`): a local that is declared but never
          read. Produced while validating; shown by default. Carries a
          quick-fix `edit` that inserts a `_` at the name's start.
        - `unused-field` (groups `unused`, `correctness`): a module field (a
          function or global) that is defined but never referenced, exported, or
          used as the start function. The module-level analog of `unused-local`;
          prefix its name with `_` to silence one. Shown by default.
        - `unused-import` (groups `unused`, `correctness`): an imported function
          or global that is never referenced, exported, or used as the start
          function. Like `unused-field`, but for imports; `_` silences one. Shown
          by default.
        - `unused-label` (groups `unused`, `correctness`): a block label that
          is declared but never branched to. Prefix its name with `_` to silence
          one. Shown by default. On the Wax side it carries a quick-fix `edit`
          that deletes the whole `'name:` prefix.
        - `shift-count-overflow` (group `correctness`): a shift by a constant
          count at least the operand's bit width. Wasm masks the count modulo
          the width, so the shift is almost certainly not what was meant. Shown
          by default.
        - `constant-trap` (group `correctness`): an operation that always traps
          on a constant operand: an integer division or remainder by zero, or a
          trapping float-to-integer conversion of an out-of-range constant.
          Shown by default.
        - `tautological-comparison` (group `correctness`): a comparison whose
          result is constant regardless of its variable operand: an unsigned
          comparison against zero (`x >=u 0`, `x <u 0`), or two identical
          operands (`x == x`). Shown by default.
        - `constant-condition` (group `correctness`): a branch, loop, or
          `select` condition that is a constant literal (the idiomatic infinite
          loop `while <nonzero>` is not flagged). Shown by default.
        - `unused-result` (group `correctness`): the result of a
          side-effect-free expression is computed and then discarded, as in
          `_ = x + 1`. Covers reads, constants, pure arithmetic, and heap
          allocations (a discarded struct/array literal) whose operands are
          themselves effect-free. Shown by default.
        - `dead-code` (group `correctness`): a statement that can never be
          reached, following an unconditional branch, `return`, or
          `unreachable`. Shown by default.
        - `cast-always-fails` (group `correctness`): a reference cast or test
          whose operand can never have the target type (the two are unrelated in
          the type hierarchy), so the cast always traps and the test is always
          false. Shown by default.
        - `eager-select` (group `correctness`): a trapping or effectful
          operation in a branch of a `?:` (which compiles to a `select`,
          evaluating both branches unconditionally), so it runs even when the
          condition selects the other branch. Shown by default. On Wasm input
          the check covers a folded `select` (its value operands are distinct
          subtrees); an unfolded `select` is not flagged.
        - `precedence` (group `correctness`): two operators whose relative
          precedence is easy to misremember are mixed without parentheses: a
          shift (`<<`/`>>`) with arithmetic (`+`, `-`, …), or a comparison with
          a bitwise operator (`&`, `|`, `^`). The code is correct, but a reader
          may misread the grouping (`1 << nbits - 1` is `1 << (nbits - 1)`).
          Shown by default. Wax-only: WAT/Wasm have no infix precedence. Carries
          a quick-fix `edit` that wraps the tighter-binding sub-expression in
          parentheses.
        - `redundant-operation` (group `redundant`): an operation with no effect
          on its result: an arithmetic identity (`x + 0`, `x * 1`, `x << 0`, …),
          an absorbing operand (`x * 0`, `x & 0`), two identical operands
          (`x - x`, `x ^ x`), a self-assignment (`x = x`), or a cast to a type
          the operand already has. **Hidden by default** (these are common in
          generated code); enable with `-W redundant=warning`.
        - `truncated-coverage`: path-sensitive validation gave up after too
          many conditional configurations. Shown by default.
        - `naming-conflict` (group `naming`): converting from Wasm, a source
          name collided with another and was renamed (e.g. `foo` → `foo_2`).
          Hidden by default.
        - `reserved-word-rename` (group `naming`): converting from Wasm, a
          source name is a Wax reserved word and was renamed (e.g. `if` →
          `if_2`). Hidden by default.
        - `generated-name` (group `naming`): converting from Wasm, an unnamed
          but referenced parameter was given a generated name (e.g. `x`), since
          it cannot be rendered anonymously. Hidden by default.
        - `compound-assignment` (group `suggestion`): a plain assignment
          `x = x op e` can be written with the compound operator `x op= e`
          (arithmetic and bitwise operators only; `x` must be the operator's
          *first* operand, so `x = e - x` is left alone). Hidden by default.
        - `field-punning` (group `suggestion`): a struct field initialised from
          the like-named local or global, `{x: x}`, can use the punning
          shorthand `{x}`. Hidden by default.
        - `redundant-annotation` (group `suggestion`): a type the inferred type
          already makes redundant and so can be dropped: a `let` annotation
          (`let x: t = e` → `let x = e`, including the anonymous `_: t = e` and
          each binding of a tuple `let (a: t, b) = e`), a module-level global
          annotation (`let counter: i32 = 0` → `let counter = 0`, likewise for a
          `const`), a construction type name (`{T| …}` → `{…}`), a block result
          type (`do t { … }` → `do { … }`), or an `if` result type
          (`if c => t { … }` → `if c { … }`). Hidden by default.
    - The `suggestion` group is reported at a distinct **Suggestion** severity
      (not a warning), and each entry carries a machine-applicable rewrite. These
      are optional simplifications, so they are hidden by default and surface as
      on-demand quick fixes in the VS Code extension; `wax check` prints them
      when enabled with `-W suggestion=warning` (or an individual name). A
      redundant *cast* removal is offered too, but as a fix attached to the
      existing `redundant-operation` warning rather than a separate suggestion.
    - *LEVEL* is one of:
        - `hidden`: suppress the warning entirely.
        - `warning`: report it as a warning.
        - `error`: promote it to an error, so the run fails.
    - Repeatable; later settings override earlier ones. For example,
      `-W all=error -W unused-local=warning` makes every warning fatal except
      unused locals.
    - The validation warnings (`truncated-coverage`, and the `unused` and
      `correctness` lints) are produced only while validating.
      `truncated-coverage` can arise from the validation `convert` runs on a
      text input; the `unused`/`correctness` lints are turned on only by
      `--validate`, and always for `check`. The `naming` warnings are produced
      when converting a Wasm module to Wax.
    - Almost all of these lints apply to WebAssembly text/binary input as well
      as Wax: the Wasm validator runs the same checks, so `wax check foo.wat`
      reports them. (The exceptions are `precedence`, which is Wax-only since
      WAT/Wasm have no infix precedence, and `eager-select`, whose Wasm side
      covers only a folded `select`.) On Wasm input `unused-result` covers discarding a constant or
      a pure `local.get`/`global.get` read; for `unused-label` a numeric `br N`
      counts as a use of the label `N` levels out; `cast-always-fails` and
      `redundant-operation` reason about `ref.cast`/`ref.test` and constant
      operands directly from the bytecode. As with `unused-local`, they fire only
      when unused reporting is on (under `check`, or under a conversion with
      `--validate`).
    - The `WAX_WARN` environment variable sets default levels applied *before*
      the `-W` options. Its value is a list of `NAME=LEVEL` specs separated by
      commas or whitespace, e.g. `WAX_WARN="correctness=hidden
      unused-local=error"`. Unlike a plain environment fallback, these defaults
      still apply when `-W` is given: the command line only refines them (so
      `WAX_WARN=correctness=hidden` with `-W dead-code=warning` hides the tier
      except dead code). A malformed or unknown entry is reported on stderr and
      skipped.

- **`--color`** *WHEN*
    - Colorize output.
    - Values: `always`, `never`, `auto`.
    - Default: `auto` (colors enabled only if output is a TTY).

- **`--error-format`** *FORMAT*
    - How diagnostics are rendered.
    - Values: `human` (source snippets, the default), `json`, or `short`.
    - With `json`, every diagnostic — errors, warnings, and syntax errors — is
      written to stderr as one JSON object per line (JSON Lines), for an editor,
      CI job, or AI assistant to parse. Each object has `severity`, `file`,
      `startLine`/`startColumn`/`endLine`/`endColumn` (1-based line, 0-based
      column), `startOffset`/`endOffset` (byte offsets), `message`, `warning`
      (the [`-W`](#options) name, or null), `hint`, and `related`. A diagnostic
      carrying a machine-applicable fix (a `suggestion`, a fixable warning like a
      redundant cast, an unused local, an unused label, or a confusing precedence
      mix, or a syntax error whose recovery insertion derives one — e.g. a
      missing `;`, under [`--all-errors`](#check)) also has an `edit` object: the
      same span fields for the slice to replace (an empty span, for an
      insertion), plus its `newText`. Syntax errors report their `hint` and
      `related` here too.
    - With `short`, each diagnostic is one
      `file:line:col: severity: message` line (gcc/rustc style, 1-based column),
      for an editor with a line-based error parser (Vim's `errorformat`, Emacs
      Flymake, …). A named warning's `-W` name is appended as `[name]`.
    - Exit codes are unchanged. Also accepted by `check` and `format`.


- **`--fold`**
    - Fold instructions into nested S-expressions.
    - Affects WAT output (the default form is chosen automatically).

- **`--unfold`**
    - Unfold instructions into flat instruction lists.
    - Affects WAT output (the default form is chosen automatically).

- **`--desugar`**
    - Expand the Wax-specific `(@string …)` and `(@char …)` annotations into
      core WebAssembly (`array.new_fixed` / `i32.const`), so the output is plain
      WebAssembly text that other tools accept. An `i8` string keeps its raw
      UTF-8 bytes; an `i16` string is UTF-16-encoded; an untyped string reuses an
      existing `(array (mut i8))` type when the module has one and otherwise pins
      a synthesised one. A module-level `(@string …)` global becomes an ordinary
      global.
    - Synthesises the declarative element segment (`(elem declare func …)`) that
      Wax's lenient reader lets a module omit for a function used by `ref.func`
      only inside a body, so the output passes strict/spec reference validation.
      This heals a conditional module: WAT emitted from a `#[if]` module keeps
      its `(@if …)` and omits the segment, but once the conditionals are resolved
      with `-D` and desugared the segment is added. It is a no-op when the
      segment is already present (as on the wax-to-wat and binary-to-wat paths).
    - Only valid with wat output (`-f wat`); requesting it for wasm or wax
      output is a usage error.
    - Fails (exit `128`) if a conditional-compilation directive `(@if …)`
      remains unresolved; resolve them first with `-D`/`--define`.
    - A `(@feature "…")` declaration is stripped: no annotation remains in the
      output. Feature resolution has already run by then, so the declaration
      still gates during processing; re-ingesting the desugared text needs
      `-X` again, exactly as desugared strings do not come back as literals.
      A module *using* gated constructs is not an error — those are real
      (proposal) WebAssembly, and removing annotations is orthogonal to
      whether the consumer supports the proposal.

- **`--source-map`**
    - Generate a source map file alongside the output file and insert a `sourceMappingURL` custom section. Only valid with wasm output (`-f wasm`) to a file;
      requesting one for wat or wax output, or when outputting to `stdout`, is an error.

- **`--debug`** *CATEGORY*
    - Enable developer debug output for a category. Repeatable, and a single
      value may list several categories separated by commas
      (`--debug timing,…`).
    - Categories:
        - `timing`: log the wall-clock running time of each compiler pass
          (parse, specialize, validate, type-check, convert, output) to stderr,
          one line per pass as it finishes. The normal output on stdout is
          unchanged.

- **`--version`**
    - Print the toolchain version and exit. In a released build this is the git
      tag it was built from; a plain development build reports `dev`.

- **`--help`**
    - Show the manual page and exit. Also available per subcommand
      (`wax format --help`, etc.).

## Examples

**Convert a Wax file to Wasm binary:**
```sh
wax input.wax -o output.wasm
```

**Convert a Wasm Text file to Wax (decompilation):**
```sh
wax input.wat -o output.wax
```

**Format a Wax file (round-trip):**
```sh
wax input.wax
```

**Read from stdin and write to stdout:**
```sh
cat input.wax | wax -f wasm > output.wasm
```

**Specialize conditional compilation while converting:**
```sh
wax input.wax -D debug=false -D ocaml_version=5.1.0 -D target=wasi -o output.wasm
```

## Formatting

The `format` subcommand reformats files in their own format (`.wat` → `.wat`,
`.wax` → `.wax`, `.wasm` → `.wasm`), detected from each file's extension.
Formatting never validates: it only re-prints; use [`check`](#checking) to
validate.

With no `FILE`, `format` reads standard input and writes the formatted result to
standard output. The format cannot be detected without a filename, so `--format`
is required in this mode (and `--inplace` / `--check`, which act on named files,
are not allowed). This is the interface an editor formatter or a shell pipe
uses:

```sh
echo 'fn f(x:i32)->i32{x*x;}' | wax format -f wax
```

```sh
wax format [OPTIONS] FILE…
```

### Options

- **`-i`**, **`--inplace`**
    - Write the formatted output back to each input file.
    - Without this flag (and without `--check`), exactly one file must be given
      and its formatted output is written to `stdout` — or no file, to format
      `stdin` to `stdout` (see above).
- **`-c`**, **`--check`**
    - Write nothing; list the files that are not already formatted and exit with
      a non-zero status if any are found. Useful in CI. Cannot be combined with
      `--inplace`.
- **`-f`**, **`--format`**, **`--input-format`** *FORMAT*
    - Treat all input files as this format (`wat`, `wasm` or `wax`), overriding
      the detection from each file's extension.
- **`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL*: set a warning's level, as
  above.
- **`--color`** *WHEN*: as above (ignored when writing back in place).
- **`--error-format`** *FORMAT*: `human`, `json`, or `short`, as above (a
  malformed file still reports its syntax error).
- **`--fold`** / **`--unfold`**: as above.
- **`--debug`** *CATEGORY*: as above.

### Examples

**Format a single file to stdout:**
```sh
wax format input.wat
```

**Reformat several files in place:**
```sh
wax format -i a.wax b.wax c.wax
```

**Check formatting in CI (non-zero exit if any file differs):**
```sh
wax format --check src/*.wax
```

## Checking

The `check` subcommand validates files (type-checking for Wax, well-formedness
for Wasm) without producing any output, reporting diagnostics and exiting with a
non-zero status if any file fails. It takes one or more files. Unused-local
warnings (see [`--validate`](#options)) are reported too, but do not by
themselves cause a non-zero exit, unless promoted to an error with
[`-W`](#options) (e.g. `wax check -W unused-local=error src/*.wax`).

```sh
wax check [OPTIONS] FILE…
```

### Options

- **`-f`**, **`--format`**, **`--input-format`** *FORMAT*: force the format of
  all files, overriding extension detection.
- **`-s`**, **`--strict-validate`**: strict reference validation for Wasm Text,
  as above (Wasm binary is always strict).
- **`-D`** *NAME[=VALUE]*, **`--define`** *NAME[=VALUE]*: set a
  conditional-compilation variable, as for [`convert`](#options): the
  conditionals are specialized before validation. A full set validates one
  configuration; a partial set leaves the remaining conditionals for the
  path-sensitive check to explore. Repeatable.
- **`-X`** *NAME[=on|off]*, **`--feature`** *NAME[=on|off]*: enable or disable
  an optional proposal, as for [`convert`](#options). Repeatable.
- **`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL*: set a warning's level, as
  above.
- **`--all-errors`**: report *every* syntax error instead of stopping at the
  first. Normally the parser gives up at the first unexpected token; with this
  flag it uses panic-mode error recovery and continues, so a single run lists
  all the syntax errors. Wax resynchronizes at statement and block boundaries
  (`;`, `}`, `)`, `]`, and the keywords that begin a new item or statement); WAT,
  being fully parenthesized, resynchronizes on the parentheses (dropping an
  incomplete group, auto-closing an unclosed one). The recovered module is then
  checked too — type-checked for Wax, validated for WAT — so genuine type or
  validation errors in the intact regions surface alongside the syntax errors,
  while the cascades a dropped construct would otherwise trigger (an unbound name
  in Wax; a warning or wrong stack height in WAT) are suppressed. Text input
  only, Wax and Wat (ignored for a Wasm binary).
- **`--color`** *WHEN*: as above.
- **`--error-format`** *FORMAT*: `human`, `json`, or `short`, as above.
- **`--debug`** *CATEGORY*: as above.

### Example

**Type-check several Wax files (e.g. in CI):**
```sh
wax check src/*.wax
```

**Report all syntax errors in a Wax file at once:**
```sh
wax check --all-errors src/foo.wax
```

## Language server

The `lsp` subcommand starts a [Language Server
Protocol](https://microsoft.github.io/language-server-protocol/) server for Wax
and WebAssembly text, speaking JSON-RPC over stdin/stdout. It runs the same
analysis the VS Code extension runs in-process, exposed to any LSP-capable
editor (Neovim, Emacs with Eglot or lsp-mode, Helix, Kakoune, Zed, and others).

```sh
wax lsp
```

It reads no files of its own; the editor tells it which documents are open.
Supported requests: diagnostics (pushed on open/change), hover,
go-to-definition, go-to-type-definition, find-references, document highlight,
rename (with prepare), document symbols (outline), completion, signature help,
inlay hints, folding ranges, selection ranges, semantic tokens, and document
formatting. The hover, navigation and completion features that need the typed
tree are Wax-only, while formatting, diagnostics and the outline work for `.wat`
too (dispatched by the document's URI extension).

A lint diagnostic carries the extra metadata editors use: the `-W` name as its
code (linked to this reference), and `DiagnosticTag.Unnecessary` on the
removable/unreachable lints (unused bindings, dead code) so the editor fades
them.

The one setting is `wax.define`, a list of conditional-compilation defines
(mirroring the [`-D`](#options) flag, e.g. `["debug=true", "arch=wasm64"]`).
Diagnostics and completion specialize to it, so a definition or an error in a
branch the defines rule out is dropped. The server reads it from the client's
`initializationOptions` at startup and from `workspace/didChangeConfiguration`
live (under a `wax` section), re-checking the open documents when it changes.

Documents are synchronized in full (each change carries the whole buffer). The
position encoding is negotiated: the server uses UTF-8 when the client offers it
and otherwise UTF-16, the LSP default that every client supports. The `--stdio`
flag is accepted (and ignored) for the editors that pass it by convention.

### Editor setup

Most editors just need the launch command `wax lsp` bound to the `wax` (and, if
desired, `wat`) file type through their LSP client. Ready-to-use configurations
for Neovim, Helix, and Emacs — paired with the `tree-sitter-wax` grammar for
highlighting — live under [`editors/`](https://github.com/ocsigen/wax/tree/main/editors)
in the repository (one directory per editor, each with a README).

## Exit status

All three commands share the same exit codes:

| Code | Meaning |
|------|---------|
| `0`  | Success. For `check` / `format --check`, also means every file passed. |
| `123` | A **usage** error: an invalid combination of flags (e.g. `--source-map` with text output, or binary output to a terminal), or a `format --check` run that found files needing formatting. |
| `124` | A command-line parse error: an unknown flag or a bad option value (reported by the argument parser). |
| `125` | An internal error (an uncaught exception). |
| `128` | The input was **rejected by a diagnostic**: a parse, validation, or type error, or a malformed wasm binary. This is also the status of a `check` run that found any problem. |

The distinction is *how you used the tool* (`123`/`124`) versus *the input is
bad* (`128`). A rejected input reports `128` wherever the error is found
(syntax, validation, or type-checking) so `check` exits `0` when every input is
valid and `128` otherwise, which is what a CI gate wants. For scripting, treat
any non-zero status as failure.

## Shell completion

`wax` supports `zsh`, `bash`, and PowerShell completion: subcommands, flag
names, flag values (`--format` → `wat`/`wasm`/`wax`, `-W`/`-X` names and values,
`--color`, `--debug`), and input/output file paths.

Completion has two halves. The generic per-shell scripts ship with the
[`cmdliner`](https://opam.ocaml.org/packages/cmdliner/) package; the `wax`
package installs its own completion definitions (and man pages) alongside the
binary. Installing `wax` through opam puts both in place. (These extra files are
installed on Unix only; they are skipped on native Windows.)

Then hook the generic scripts into your shell once. For `zsh`, ensure the
site-functions directory is on `$fpath` **before** `compinit`:

```sh
FPATH="$(opam var share)/zsh/site-functions:$FPATH"
autoload -Uz compinit && compinit
```

For `bash`, with [`bash-completion`](https://github.com/scop/bash-completion)
installed, point it at the cmdliner share directory. See the
[cmdliner completion guide](https://erratique.ch/software/cmdliner/doc/cli.html#cli_completion)
for the per-shell details and the PowerShell setup.
