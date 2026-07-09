# Module Fields

Wax modules are defined by a sequence of top-level fields: types, functions, globals, memories, tables, and tags.

## Module Name

A `#![module = "..."]` inner attribute at the top of the file names the module.
It maps to the WebAssembly module name, the symbolic name stored in the module
subsection of the `name` custom section, written `$name` in WAT:

```wax
#![module = "my_module"]
```

corresponds to the WAT

```wat
(module $my_module …)
```

A module may carry at most one name. See also
[Module Name](../language.md#module-name) in the language guide.

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
import "env" {
    const base: i32;
    let counter: i32;
}
```

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

A custom page size is written with a `pagesize` clause after the limits, mapping to the WAT `(pagesize N)` form. The page size must be `1` or `65536` (the default), and the limits are counted in pages of that size:

```wax
memory small: i32 [4096] pagesize 1;
```

```wat
(memory $small 4096 (pagesize 1))
```

A `shared` clause (the threads proposal) marks the memory shared; it must have a maximum size:

```wax
memory pool: i32 [1, 16] shared;
```

```wat
(memory $pool 1 16 shared)
```

Loads and stores use method-call syntax on the memory, with the value's width in the method name and its signedness expressed by the surrounding [`as iN_s`/`as iN_u` cast](instructions.md#memory-access), the same convention as packed array access:

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
data seg = "raw\x00bytes";
data init @ mem0 [0] = "hello";
```

Data bytes are ordinary [string literals](../language.md#strings); escapes such as `\x41` and `\x00` (two hex digits) decode to raw bytes.

## Tables

A table is declared with `table`, followed by its element [reference type](types.md) and, optionally, its limits as `[min]` or `[min, max]`:

```wax
table funcs: &?func [1, 10];
table objs: &?any [0];
```

Maps to:

```wat
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
type cmp = fn(_: i32, _: i32) -> i32;

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
import "env" tag js_error(&?extern);
```

## Attributes

Attributes modify module fields. They use the syntax `#[name = value]`, or `#[name]` when no value is needed, and appear before the field they modify.

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

The name is optional: a bare `#[export]` exports the field under its own Wax name.

```wax
#[export]
fn add(x: i32, y: i32) -> i32 { x + y; }
```

Multiple exports can share the same function:

```wax
#[export = "add"]
#[export = "plus"]
fn add(x: i32, y: i32) -> i32 { x + y; }
```

### Start Attribute

Mark a function to run at module instantiation. It takes no value and the
function must have no parameters and no results (it maps to the Wasm `start`
field):

```wax
#[start]
fn init() {
    // initialization code
}
```

## Imports

Import fields from a host module with an `import "module" { … }` block; a lone
import can use the one-line `import "module" <declaration>;` form. Each entry is
imported under its own Wax name, unless a name-only `#[import = "name"]`
overrides that.

```wax
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

```wax
import "env" #[export = "value"] const value: i32;
```

## Conditional Annotations

Both formats can guard module fields by a condition that a downstream preprocessor evaluates. Wax uses `#[if(...)] { ... }` / `#[else] { ... }`, with the braces required around each branch; WAT uses the annotation form `(@if <cond> (@then ...) (@else ...))`.

```wax
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

```wax
// 1. Type definitions
type point = { x: i32, y: i32 };
type callback = fn(_: i32) -> i32;

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
