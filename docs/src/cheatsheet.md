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
42  0x2A  0o52  0b101010  // integers (flexible: i32/i64/f32/f64 by context)
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
br 'l;   br_if 'l c;   br_table ['a 'b else 'd] i;
br_on_null 'l v;   br_on_cast 'l &t v;   // also _non_null / _cast_fail
dispatch i ['a 'b else 'd] { 'a: { } 'b: { } 'd: { } }   // jump table (falls through)
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
try t { } catch { oops => { _; }  _ => { } }     // try / catch (payload via hole _)
throw oops 42;                                   // throw
try { } catch [oops -> 'h]                       // branch-to-label form (try_table)
type k = cont ft;                                // continuation type
suspend yield(x);   resume k [tag -> 'l] (args, c);   // suspend / resume
```
