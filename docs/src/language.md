# Language Guide

This guide covers Wax syntax and semantics. For the detailed mapping to WebAssembly instructions, see [Correspondence](./correspondence/intro.md).

## Comments

Wax supports C-style comments:

```wax
// Single-line comment

/* Multi-line
   comment */
```

## Trailing Commas

A trailing comma is allowed after the last element of any comma-separated
list — function parameters, call arguments, struct fields, result types, and
so on:

```wax
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
0o52        // Octal
0b101010    // Binary
```

A numeric literal is **flexible**: it has no fixed type of its own but takes a
concrete one from its context — a type annotation, the operation it feeds, or a
function's result type.

```wax
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

```wax
let a = 42;             // unconstrained -> i32
let b = 5_000_000_000;  // too big for i32 -> i64
let c = 3.14;           // float literal -> f64
```

Once a literal is used where only integers are allowed (a bitwise op, a shift,
`ctz`, …) it commits to the **integer** family and can then only be `i32` or
`i64` — it can no longer become a float by inference. These are *implicit*
coercions; an explicit [`as` cast](#type-conversions) is broader and emits the
conversion — e.g. an out-of-range constant `as i32` wraps to its low 32 bits, and
an integer `as f64` converts.

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
character's Unicode code point as an `i32` — it is simply a readable spelling of
an `i32.const`:

```wax
'A';            // 65
'\n';           // 10
'\41';          // 65, a byte written as two hex digits
'\u{1F600}';    // 128512, a Unicode code point
```

The recognised escapes are `\t`, `\n`, `\r`, `\'`, `\"`, `\\`, `\NN` (exactly
two hex digits, one byte), and `\u{...}` (a Unicode code point in hex). For
text, see [Strings](#strings).

A character literal round-trips through WAT, where it is written with a
`(@char …)` annotation. A WASM binary keeps only the underlying `i32.const`,
though, so decompiling from WASM yields the plain integer code point.

## Variables

### Local Variables

Declare local variables with `let`. Each variable gets a type, either from an
explicit annotation or from an initializer:

```wax
fn example() -> i32 {
    let x: i32;        // annotated, no initializer
    let y = 20;        // type inferred from the initializer (i32)
    x = 10;
    x + y;
}
```

A local declared without an initializer starts at its type's zero value (`0`,
`0.0`, or `null`). When the type is omitted, it is taken from the initializer;
an otherwise-unconstrained integer literal then defaults to `i32` and a float to
`f64`. An annotation and an initializer can be combined, and must agree:

```wax
let count: i64 = 0;
```

A `let` can bind several names at once from an initializer that produces
multiple values — a call to a [multi-result function](#functions),
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

`:=` works on local variables only — WebAssembly has no `global.tee`, so applying
it to a global is an error.

### Global Variables

Globals are declared at module level. `const` is immutable; `let` is mutable:

```wax
const PI: f64 = 3.14159;        // immutable global
let counter: i32 = 0;           // mutable global
```

As with locals, an initialized global may omit its type and take it from the
initializer (an unconstrained integer literal defaults to `i32`):

```wax
const answer = 42;              // i32
```

A global's initializer must be a constant expression (a literal, another
global, or a simple reference-building expression).

### Names and Scope

Functions, globals, memories, and tables share one module-level namespace: a
name must be distinct across all four — you cannot, say, declare both a memory
and a global named `buf`. Types, tags, and data/element segments each have their
own namespace, so those names may overlap with the above and with one another.

A local variable is scoped to its function and takes precedence over module-level
names. A bare name resolves to a local before a global or function, and the
name-based module forms — `mem.load(..)`, `tab[i]`, `seg.drop()` — likewise defer
to a same-named local. So a local that reuses a memory, table, or segment name
shadows it; rename the local if you still need to reach the module entity.

## Expressions

Wax is a readable layer over WebAssembly, and it keeps WebAssembly's execution
model: the **operand stack**. A function or block body is a sequence of
statements, each ended with `;`. Evaluating a statement may push values onto the
stack and pop values off it, and whatever remains on the stack when the body
ends is its result — which must match the declared result type. A
value-returning function therefore ends with a statement that leaves that value:

```wax
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

### Unary Operations

```wax
-x          // Negate
+x          // Positive (no-op for integers)
!x          // Logical not / is_null for references
```

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
instead as a **qualified path**, `type::member(args)` — a built-in free
function namespaced by the WebAssembly type it belongs to. These names are
built in, not user functions, and because the `::` form is distinct from an
ordinary name it can never clash with your own functions, globals, or locals.

Two families use this syntax today.

**`v128::` — SIMD free functions.** The vector constants (one argument per
lane) and `bitselect`, which have no receiver:

```wax
v128::const_i32x4(1, 2, 3, 4)         // a v128 constant (also a constant expression)
v128::const_f32x4(1.5, 2.5, 3.5, 4.5)
v128::bitselect(a, b, mask)           // per-bit select
```

**`i64::` — wide arithmetic.** 128-bit integer operations, taking and returning
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

## Control Flow

### Blocks

A block groups a sequence of statements, written with `do`. (A bare `{ … }` is
accepted as shorthand for `do { … }`.)

```wax
do {
    let x: i32;
    x = compute();
    use(x);
}
```

By default a block is **void**: it produces no value, so — like a function with
no result type — its body must leave the operand stack empty.

To make a block produce a value, give it a result type after `do`. The body
must leave a value of that type on the stack, and that becomes the block's
value:

```wax
answer = do i32 {
    42;
};
```

This is a stack discipline, not a "last expression" rule: the body must leave
*exactly* the values the block's type describes — no more, no less. A void
block that leaves a value, or a `do i32` block that leaves two, is an error.

The result type may be **omitted** and inferred — from the value the body leaves
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
do (i32) -> i32 { … };    // a statement: consumes that i32, leaves an i32
_ + 1;                    // the hole plugs in the block's result
```

Blocks can be labelled and used as branch targets; see
[Labels and Branches](#labels-and-branches).

### If Expressions

`if` tests a condition — any `i32`, where non-zero means true — and runs the
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

Like a block's result type, the `=> <type>` may be **omitted** and inferred —
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

A `loop` runs its body once and then falls through to whatever follows — it does
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
*continue* — it jumps back to re-test. Decompiling recovers a `while` from this
shape, so a loop written this way survives a round trip through WAT or WASM.

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
jumps to its *start* (an iteration — see [Loops](#loops)).

```wax
'done: do {
    if condition {
        br 'done;   // jump past the block — exits it
    }
    // ...
}
```

Branch instructions:

```wax
br 'label;                          // unconditional branch
br_if 'label cond;                  // branch if cond (an i32) is non-zero
br_table ['a 'b else 'default] i;   // branch to the i-th label, else 'default
```

The labels in a `br_table` are separated by spaces, and `else` gives the
fallback for an out-of-range index. A branch also carries any values its target
expects — a `do i32` target receives an `i32`, and so on.

### Dispatch

A `dispatch` is a multi-way branch — the readable form of a `br_table` jump
table. A bracket maps an index to a case label (with an `else` default for an
out-of-range index), and each arm gives that case's body:

```wax
fn classify(x: i32) -> i32 {
    dispatch x ['zero 'one 'two else 'big] {
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
fall-through order, which is the reverse of the bracket's index order — the
last arm is the one index `0` reaches. The example above gives each case its
own result via `return`; to break out instead, branch to an enclosing label:

```wax
let r: i32;
'done: do {
    dispatch x ['zero 'one else 'two] {
        'two:  { r = 30; }
        'one:  { r = 20; br 'done; }
        'zero: { r = 10; br 'done; }
    }
}
```

This is the shape compilers emit for a dense switch, so decompiling WAT/WASM to
Wax recovers `dispatch` from it (and a Wax `dispatch` round-trips through the
binary).

### Match

A `match` is a multi-way *type* test — the readable form of the nested type-test
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

`match` lowers to a nested ladder of blocks — one per arm plus an outer *escape*
block. The scrutinee is threaded through a `br_on_cast` (or `br_on_null` for a
`null` arm) chain in the innermost block; each test, on success, branches *out*
to its arm's block carrying the narrowed value, and the arm body follows that
block. As with `dispatch`, an arm's body must leave the `match` (here each
`return`s); to continue past it, branch to an enclosing label. When no test
matches, the chain falls through to a `br` past all the arm bodies, and the
default follows the escape block as trailing code — so reaching it falls through
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

This is the shape hand-written GC code uses, so decompiling WAT/WASM to Wax
recovers `match` from such a ladder — even a single type test that branches out
and then falls through to a default (and a Wax `match` round-trips through the
binary).

### Return

```wax
return value;
```

### Tail Calls

Use `become` for tail calls (guaranteed not to grow the stack):

```wax
fn factorial_helper(n: i32, acc: i32) -> i32 {
    if n <=s 1 => i32 {
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

A function may return several values, written as a parenthesized list; the body
leaves them all on the stack, in order:

```wax
fn divmod(a: i32, b: i32) -> (i32, i32) {
    a /s b;
    a %s b;
}
```

### Start Function

A function marked with the `#[start]` attribute runs automatically when the
module is instantiated. It must take no parameters and return nothing, and a
module may have at most one:

```wax
#[start]
fn init() {
    // initialization code
}
```

(This maps to the WebAssembly `start` field; see
[Module Fields](./correspondence/module_fields.md#start-attribute).)

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

Structs and arrays are WebAssembly GC heap types: a value of such a type is
always held through a reference (`&point`, `&bytes`, …), not inline.

## Structs

### Definition

A struct is a named record. Mark a field `mut` to allow assignment after
creation; a plain field is set only at creation time. A value of `type point`
is held as `&point`.

```wax
type point = { x: i32, y: i32 };
type mutable_point = { x: mut i32, y: mut i32 };
```

### Creation

`{T| …}` allocates a new struct of type `T` and yields a `&T`. Give every field
a value, or use `..` to default them all (each field type must have a zero/null
default):

```wax
{point| x: 10, y: 20}       // all fields given
{point| ..}                 // every field defaulted
```

The type name may be omitted in two cases. The first is when an expected type
supplies it — for example a `let`/`const` annotation, a function parameter, a
struct field, or an array element: `let p: &point = {x: 10, y: 20};` is
equivalent to writing `{point| …}`. Such an expectation also reaches into both
branches of a conditional `?:`, so a branch may omit the name (or default it
with `{..}`): `let p: &point = cond ? {x: 0, y: 0} : {..};`. The second is when
the **field set** names the type unambiguously — if exactly one struct type in
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

### Field Access

```wax
p.x                         // read a field
p.x = 42;                   // write a field (only if it is `mut`)
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
[bytes| seg @ 0; 100]       // New array from a data segment (offset, count)
```

The last form is `array.new_data`: it initializes the array from the named [data segment](#data-segments) `seg`, reading `count` elements starting at byte `offset`.

As with structs, the type name may be omitted when an expected type supplies it,
e.g. `let xs: &bytes = [0; 100];`.

### Element Access

```wax
arr[i]                      // Get element
arr[i] = val;               // Set element (if mutable)
arr.length()                // Array length
```

## Strings

A string literal builds a new array, one element per byte of the (UTF-8) text.
By default its type is `[mut i8]`, and it lowers to an `array.new_fixed`:

```wax
"hello";                    // a new [mut i8] holding the 5 bytes
```

As with [array](#arrays) and [struct](#structs) literals, a different array type
can be selected — either by prefixing the string with the type name and `#`, or
by an expected type from the context. The element type must be numeric or packed
(`i8`, `i16`, `i32`, …):

```wax
type chars = [i8];

chars # "hi";               // a &chars (explicit type)
let s: &chars = "yo";       // type taken from the annotation
```

String literals recognise the same escapes as [character literals](#characters)
— `\t`, `\n`, `\r`, `\'`, `\"`, `\\`, `\NN` (two hex digits, one byte), and
`\u{...}` (a Unicode code point, encoded as its UTF-8 bytes):

```wax
"tab\tend";
"smile \u{1F600}";
```

A string also supplies the bytes of a [data segment](#data-segments).

A string literal round-trips faithfully through WAT, where it is written with a
`(@string …)` annotation. Through WASM it is best-effort: the binary keeps only
the `array.new_fixed`, which is recovered as a string literal only when its
bytes form a *reasonable* UTF-8 string — valid UTF-8 with no control characters
other than tab, newline, and carriage return. Anything else (arbitrary binary
data) decompiles as an ordinary [array literal](#arrays) instead.

## Memories

### Declaration

```wax
memory mem0: i32 [1, 1000];     // address type i32, min 1 page, max 1000
memory mem1: i64 [2];           // min 2 pages, no maximum
memory mem2: i32;               // size derived from data segments
```

A memory may declare a custom page size with a `pagesize` clause after its
limits. The page size is a byte count and must be `1` or `65536` (the default);
limits are then counted in pages of that size:

```wax
memory small: i32 [4096] pagesize 1;      // 4096 pages of 1 byte
memory mem3: i32 [1, 1000] pagesize 65536; // the default page size, explicit
```

A memory may be declared `shared` (the threads proposal), for use with atomic
accesses across threads. A shared memory must specify a maximum size:

```wax
memory pool: i32 [1, 16] shared;
```

### Atomics

Atomic memory operations are methods on a memory, named after the WebAssembly
mnemonic with `.` rewritten as `_` (the value type is part of the name):

```wax
mem.i32_atomic_load(p)              // atomic load
mem.i32_atomic_store(p, v);         // atomic store
mem.i32_atomic_rmw_add(p, v)        // read-modify-write, returns the old value
mem.i64_atomic_rmw16_add_u(p, v)    // narrow (16-bit) RMW on an i64
mem.i32_atomic_rmw_cmpxchg(p, expected, replacement)
mem.atomic_notify(p, count)         // wake waiters
mem.atomic_wait32(p, expected, timeout)
```

An atomic access must use its natural alignment. `atomic.fence`, which has no
memory operand, is written as the [`atomic::fence()`](#qualified-intrinsics)
intrinsic.

### Data Segments

```wax
memory mem1: i64 {
    data _ @ [0x1000] = "hello world";   // active, anonymous
    data greeting @ [0x2000] = "hi";     // active, named
}

data seg = "raw\00bytes";                // top-level passive segment
data init @ mem0 [0] = "hello";          // top-level active segment
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
mem0.store32(p, v, 1, 16);  // align=1, offset=16
```

The two optional trailing arguments are the access `align` and `offset` (constant integers).

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

A passive element segment initializes a GC array of references with the same `[t| seg @ off; count]` form used for data segments — a reference element type selects the element segment:

```wax
[handlers| pool @ 0; 3]               // array.new_elem
```

## Exceptions

### Tags

A tag declares an exception, optionally carrying a payload. The parameter list
is required — write `()` for no payload:

```wax
tag stop();                 // no payload
tag overflow(i32);          // carries an i32
tag pair(i32, f64);         // carries several values
```

### Throw

`throw` raises a tag together with its payload:

```wax
throw overflow 42;
```

### Try / Catch

A `try` runs its body and routes a matching thrown tag to a handler. Like a
block it may carry a result type (`try i32 { … }`) that the body and every
handler produce. A caught tag's payload is left on the operand stack for the
handler to pick up with a [hole](#holes) `_`:

```wax
fn lookup(k: i32) -> i32 {
    try i32 {
        find(k);             // may throw `overflow`
    } catch {
        overflow => { _; }   // `_` is the thrown i32 payload
        _ => { 0; }          // catch-all
    }
}
```

Each `tag => { … }` handler matches one tag; a bare `_ => { … }` matches any
exception. Leave the catch-all out to let unmatched exceptions propagate.

### Branching handlers (try_table)

A lower-level form branches to a label instead of running an inline handler,
mapping directly to WebAssembly's `try_table`:

```wax
try { might_throw(); } catch [overflow -> 'h]    // on `overflow`, branch to 'h
try { might_throw(); } catch [overflow & -> 'h]  // also deliver the exnref
try { might_throw(); } catch [_ -> 'h]           // catch any exception
```

The target label receives the payload (and, with `&`, the `exnref`), so the
labelled block's type must match what it is handed.

## Holes

A hole (`_`) is a placeholder for a value that an **earlier statement in the
same sequence** has left on WebAssembly's implicit operand stack. It is the
surface syntax for that stack flow: rather than naming an intermediate value,
you leave a hole where it should be plugged in.

```wax
fn example() -> i32 {
    1; 2; _ + _;    // Equivalent to: let a = 1; let b = 2; a + b
}
```

Here the statements `1` and `2` each push a value; the two holes in `_ + _`
consume them.

**How many, and in what order.** The number of holes in an expression is the
number of stack values it pulls in. They are filled **left-to-right with the
stack values in the order those values were produced** — the earliest value
fills the leftmost hole. Order therefore matters for non-commutative
operators:

```wax
fn diff() -> i32 {
    10; 20; _ - _;    // 10 - 20, not 20 - 10
}
```

A single hole is common when combining one stacked value with an explicit
operand:

```wax
fn add_one(x: i32) -> i32 {
    x; _ + 1;
}
```

**Holes must come first.** Within an expression, every hole must precede (in
evaluation order) any explicit value-producing operand. Once a non-hole operand
appears, no further holes may follow it. Explicit operands *after* all the holes
are fine:

```wax
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

When decompiling WASM or WAT back to Wax, the compiler introduces holes wherever
an instruction takes an operand from the stack instead of from a nested
sub-expression, so this same mechanism round-trips stack-style code.

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

Variables can be given values on the command line with [`-D`/`--define`](cli.md), which specializes the conditionals: a condition that becomes fully determined causes its conditional to be removed (the surviving branch is spliced in), and one that still mentions unset variables is kept with its condition simplified. For example, `wax -D debug=true` turns `#[if(all(debug, target = "wasi"))]` into `#[if(target = "wasi")]`, and `wax -D debug=false` removes that conditional altogether.

When type checking is enabled (`--validate`), every reachable combination of conditions is checked independently. Because branches are mutually exclusive, a name defined in both the `#[if]` and `#[else]` branch is accepted. An error that occurs only under some conditions is reported together with the assumption that makes it reachable:

```
Error: Expecting type i32 but got type float.
 ──➤  example.wax:4:16
Hint: reachable when not debug
```
