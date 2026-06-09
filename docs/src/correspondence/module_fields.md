# Module Fields

Wax modules are defined by a sequence of top-level fields: types, functions, globals, tags, memories, and data segments.

## Types

Types are defined using `type` for single definitions or `rec { ... }` for mutually recursive types.

### Simple Types

```wax
type point = { x: i32, y: i32 };
type bytes = [i8];
type callback = fn(_: i32) -> i32;
```

### Recursive Types

Use `rec` when types reference each other:

```wax
rec {
    type list = { head: i32, tail: &?node };
    type node = { rest: &list };
}
```

### Supertypes and Finality

Types are final (non-extensible) by default. Use `open` to allow subtypes:

```wax
type shape = open { x: i32, y: i32 };
type circle : shape = { x: i32, y: i32, radius: i32 };
```

Maps to:

```wat
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

```wax
fn log_value(x: i32) {
    // no return
}
```

### Function Signatures (Declarations)

Declare a function signature without a body (used with imports):

```wax
fn external_function(x: i32) -> i32;
```

### Block Type Annotation

Functions can have a block type on the body:

```wax
fn example() -> i32 'label: {
    // body can use 'label
}
```

## Globals

### Immutable Globals

```wax
const PI: f64 = 3.14159;
const MAX_SIZE: i32 = 1024;
```

### Mutable Globals

```wax
let counter: i32 = 0;
let state: &?any = null;
```

### Imported Globals

```wax
#[import = ("env", "base")]
const base: i32;

#[import = ("env", "counter")]
let counter: i32;
```

## Tags

Tags define exception types for structured exception handling.

### Definition

```wax
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

```wax
tag yield(value: i32) -> i32;
```

### Imported Tags

```wax
#[import = ("env", "js_error")]
tag js_error(&?extern);
```

## Attributes

Attributes modify module fields. They use the syntax `#[name = value]` and appear before the field they modify.

### Export Attribute

Export a field with a given name:

```wax
#[export = "add"]
fn add(x: i32, y: i32) -> i32 { x + y; }

#[export = "PI"]
const PI: f64 = 3.14159;

#[export = "my_error"]
tag my_error(code: i32);
```

Multiple exports can share the same function:

```wax
#[export = "add"]
#[export = "plus"]
fn add(x: i32, y: i32) -> i32 { x + y; }
```

### Import Attribute

Import a field from a module. Takes a tuple of `("module", "name")`:

```wax
#[import = ("env", "log")]
fn log(msg: i32);

#[import = ("env", "memory_base")]
const memory_base: i32;

#[import = ("env", "error")]
tag error(code: i32);
```

### Combined Import and Export

A field can be both imported and re-exported:

```wax
#[import = ("env", "value")]
#[export = "value"]
const value: i32;
```

## Conditional Annotations

Both formats can guard module fields by a condition that a downstream preprocessor evaluates. Wax uses `#[if(...)]` / `#[else]`; WAT uses the annotation form `(@if <cond> (@then ...) (@else ...))`.

```wax
#[if(ocaml_version >= (5, 1, 0))]
const size: i32 = 16;
#[else]
const size: i32 = 20;
```

```wat
(@if (>= $ocaml_version (5 1 0))
  (@then (global $size i32 (i32.const 16)))
  (@else (global $size i32 (i32.const 20))))
```

The conditions are equivalent — note the surface differences: Wax variables are bare (`ocaml_version`) while WAT variables are `$`-prefixed; Wax versions are tuples `(5, 1, 0)` while WAT writes them `(5 1 0)`; Wax combines conditions with `all`/`any`/`not`, WAT with `and`/`or`/`not`.

The conditions are preserved, not evaluated. Type checking (`--validate`) explores each reachable combination independently (see the [Language Guide](../language.md#conditional-compilation)). Conversion between the Wax and WAT forms is not yet implemented; conditionals are currently supported within each format on its own.

## Memories

A memory is declared with `memory`, followed by its address type (`i32` or `i64`) and, optionally, its limits as `[min]` or `[min, max]` (in pages of 64 KiB):

```wax
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

Loads and stores use method-call syntax on the memory, with the value's width in the method name and its signedness expressed by the surrounding [`as iN_s`/`as iN_u` cast](instructions.md#memory-access) — the same convention as packed array access:

```wax
let x: i32 = mem0.load32(p);
let b: i32 = mem0.load8(p) as i32_u;
mem0.store16(p, v);
mem0.store32(p, v, 1, 16);     // align=1, offset=16
```

See [Memory Access](instructions.md#memory-access) for the full instruction mapping.

### Data Segments

A memory declaration may carry active data segments in a block, placed at a constant offset:

```wax
memory mem1: i64 {
    data _ @ [0x1000] = "hello world";
    data greeting @ [0x2000] = "hi";
}
```

Top-level `data` defines a passive segment, or an active segment for a named memory:

```wax
data seg = "raw\00bytes";
data init @ mem0 [0] = "hello";
```

Data bytes are ordinary string literals; escapes such as `\xNN` and `\00` decode to raw bytes.

## Tables

Wax does not provide dedicated syntax for tables; table definitions are dropped on conversion from WAT/WASM (Wax uses typed function references instead). If you need tables, write that portion in WAT and link it with your Wax code.

## Module Structure

A typical Wax module follows this structure:

```wax
// 1. Type definitions
type point = { x: i32, y: i32 };
type callback = fn(_: i32) -> i32;

// 2. Imported globals and functions
#[import = ("env", "log")]
fn log(value: i32);

#[import = ("env", "base")]
const base: i32;

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
