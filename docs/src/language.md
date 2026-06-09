# Language Guide

This guide covers Wax syntax and semantics. For the detailed mapping to WebAssembly instructions, see [Correspondence](./correspondence/intro.md).

## Comments

Wax supports C-style comments:

```wax
// Single-line comment

/* Multi-line
   comment */
```

## Literals

### Integers

```wax
42          // Decimal
0x2A        // Hexadecimal
0o52        // Octal
0b101010    // Binary
```

Integer literals are typed based on context. Suffix with `_i64` for 64-bit:

```wax
let x: i64 = 42;        // Inferred from type annotation
let y: i64 = 42_i64;    // Explicit suffix
```

### Floating Point

```wax
3.14        // Decimal
1.0e10      // Scientific notation
0x1.5p10    // Hexadecimal float
inf         // Infinity
nan         // Not a number
```

## Variables

### Local Variables

Declare local variables with `let`. Variables must be typed:

```wax
fn example() -> i32 {
    let x: i32;
    let y: i32;
    x = 10;
    y = 20;
    x + y;
}
```

You can declare multiple variables:

```wax
let x: i32, y: i32, z: f64;
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

### Global Variables

Globals are declared at module level:

```wax
const PI: f64 = 3.14159;        // Immutable global
let mut counter: i32 = 0;       // Mutable global
```

## Expressions

Wax is expression-oriented. Most constructs produce values.

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

### Unary Operations

```wax
-x          // Negate
+x          // Positive (no-op for integers)
!x          // Logical not / is_null for references
```

### Method-Style Operations

Some operations use method syntax:

```wax
x.abs       // Absolute value
x.neg       // Negate
x.sqrt      // Square root
x.floor     // Floor
x.ceil      // Ceiling
x.trunc     // Truncate
x.nearest   // Round to nearest
x.clz       // Count leading zeros
x.ctz       // Count trailing zeros
x.popcnt    // Population count
x.extend8_s   // Sign-extend the low 8 bits
x.extend16_s  // Sign-extend the low 16 bits
```

Two-argument operations also use method syntax, with the second operand
passed as an argument:

```wax
x.min(y)
x.max(y)
x.copysign(y)
x.rotl(y)      // Rotate left
x.rotr(y)      // Rotate right
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
x.to_bits       // Reinterpret float as int
x.from_bits     // Reinterpret int as float
```

### Conditional Expression

```wax
cond ? val_true : val_false
```

This maps directly to Wasm's `select` instruction.

## Control Flow

### Blocks

A block is a sequence of expressions. The last expression is the block's value:

```wax
{
    let x: i32;
    x = compute();
    x + 1;
}
```

Use `do` with a type annotation when the block returns a value:

```wax
do i32 {
    42;
}
```

### If Expressions

```wax
if condition {
    then_branch;
} else {
    else_branch;
}
```

With a result type:

```wax
if condition => i32 {
    1;
} else {
    0;
}
```

### Loops

Loops repeat until explicitly broken out of:

```wax
loop {
    // body
    br 'loop;   // Continue looping
}
```

With a label:

```wax
'outer: loop {
    'inner: loop {
        br 'outer;  // Break to outer
    }
}
```

### Labels and Branches

Labels start with `'` and are used with branch instructions:

```wax
'my_block: do {
    if condition {
        br 'my_block;   // Exit the block
    }
    // ...
}
```

Branch instructions:

```wax
br 'label;              // Unconditional branch
br_if 'label cond;      // Branch if condition is true
br_table ['a, 'b else 'default] index;  // Branch table
```

### Return

```wax
return value;
```

### Tail Calls

Use `become` for tail calls (guaranteed not to grow the stack):

```wax
fn factorial_helper(n: i32, acc: i32) -> i32 {
    if n <= 1 {
        acc;
    } else {
        become factorial_helper(n - 1, n * acc);
    }
}
```

## Functions

### Definition

```wax
fn name(param1: type1, param2: type2) -> return_type {
    body;
}
```

Functions without a return type return nothing:

```wax
fn log_value(x: i32) {
    // side effects only
}
```

### Function Types

Function types use `fn`:

```wax
type binary_op = fn(i32, i32) -> i32;
```

Anonymous parameters use `_`:

```wax
type callback = fn(_: i32) -> i32;
```

### Calls

```wax
result = my_function(arg1, arg2);
```

### Indirect Calls

Call through a function reference:

```wax
(func_ref as &?callback)(arg)
```

## References

### Reference Types

```wax
&type           // Non-nullable reference
&?type          // Nullable reference
```

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

## Structs

### Definition

```wax
type point = { x: i32, y: i32 };
type mutable_point = { mut x: i32, mut y: i32 };
```

### Creation

```wax
{point| x: 10, y: 20}       // New struct with explicit type
{point| ..}                 // New struct with default values
```

### Field Access

```wax
p.x                         // Get field
p.x = 42;                   // Set field (if mutable)
```

## Arrays

### Definition

```wax
type bytes = [i8];
type mutable_ints = [mut i32];
```

### Creation

```wax
[bytes| 0; 100]             // New array: 100 elements, all 0
[bytes| ..; 100]            // New array: 100 elements, default value
[bytes| 1, 2, 3, 4]         // New array with specific values
```

### Element Access

```wax
arr[i]                      // Get element
arr[i] = val;               // Set element (if mutable)
arr.length                  // Array length
```

## Exceptions

### Tags

Define exception tags:

```wax
tag my_error(code: i32);
```

### Throw

```wax
throw my_error(42);
```

### Try/Catch (try_table style)

```wax
'handler: do {
    try {
        might_throw();
    } catch [my_error -> 'handler]
}
```

With reference to exception:

```wax
try {
    might_throw();
} catch [my_error & -> 'handler]    // & captures the exnref
```

Catch all:

```wax
try {
    might_throw();
} catch [_ -> 'handler]             // Catch any exception
```

### Try/Catch (legacy style)

```wax
try {
    might_throw();
} catch {
    my_error => { handle_error(); }
    _ => { handle_any(); }
}
```

## Holes

Wax supports holes (`_`) as placeholders for values that can be inferred from earlier expressions in a sequence:

```wax
fn example() -> i32 {
    1; 2; _ + _;    // Equivalent to: let a = 1; let b = 2; a + b
}
```

This is useful for writing concise code where intermediate values flow naturally.

## Conditional Compilation

Top-level items can be guarded by conditions, using a Rust-like attribute syntax. `#[if(<condition>)]` keeps the following item only when `<condition>` holds; an optional `#[else]` provides an alternative:

```wax
#[if(ocaml_version >= (5, 1, 0))]
const caml_marshal_header_size: i32 = 16;
#[else]
const caml_marshal_header_size: i32 = 20;
```

A condition is one of:

- a **boolean variable**, e.g. `debug`;
- a **comparison** `variable op literal`, where `op` is `=`, `!=`, `<`, `<=`, `>` or `>=`, and the literal is either a **version** tuple `(major, minor, patch)` or a **string** `"..."`:

  ```wax
  #[if(feature = "gc")]
  #[if(ocaml_version >= (5, 1, 0))]
  ```

- a **combination** built with `all(...)` (conjunction), `any(...)` (disjunction) or `not(...)` (negation), nested arbitrarily:

  ```wax
  #[if(all(debug, not(target = "wasm32")))]
  ```

To guard several items at once, follow the attribute with a block:

```wax
#[if(debug)]
{
    const debug_enabled: i32 = 1;
    fn debug_log(msg: i32) {
        // ...
    }
}
```

The conditions are **not evaluated** by the compiler; they are preserved for a downstream preprocessor. The `#[if]` and `#[else]` branches are **mutually exclusive** — they never coexist — so, for instance, the same name may be defined in both.

When type checking is enabled (`--validate`), every reachable combination of conditions is checked independently. Because branches are mutually exclusive, a name defined in both the `#[if]` and `#[else]` branch is accepted. An error that occurs only under some conditions is reported together with the assumption that makes it reachable:

```
Error: This instruction has type float but is expected to have type i32.
 ──➤  example.wax:4:16
Hint: reachable when not debug
```
