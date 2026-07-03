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

```wat
(module $calculator
  (func $square (export "square") (param $x i32) (result i32)
    local.get $x
    local.get $x
    i32.mul))
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

```wat
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

```wat
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
    let i: i32;
    let len: i32;
    len = arr.length();
    i = 0;
    'search: loop {
        if i >=s len {
            return -1;
        }
        if arr[i] == 0 {
            return i;
        }
        i = i + 1;
        br 'search;
    }
    unreachable;
}
```

### Equivalent WAT

```wat
(func $find_first_zero (export "find_first_zero")
      (param $arr (ref $array_i32)) (result i32)
  (local $i i32)
  (local $len i32)
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

```wat
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
    dispatch color ['red 'green 'blue else 'bad] {
        'bad:   { return -1; }
        'blue:  { return value & 255; }
        'green: { return (value & 255) << 8; }
        'red:   { return (value & 255) << 16; }
    }
}
```

### Equivalent WAT

```wat
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
    {point| x: x, y: y};
}

#[export = "distance_squared"]
fn distance_squared(p1: &point, p2: &point) -> i32 {
    let dx: i32;
    let dy: i32;
    dx = p1.x - p2.x;
    dy = p1.y - p2.y;
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

// Where an expected type fixes the result — here a `let` annotation — the
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
// expected type — only `point` has the fields {x, y}, so its name may be
// dropped here too.
#[export = "make_origin"]
fn make_origin() -> &eq {
    {x: 0, y: 0};
}

// The expected type also reaches into both branches of a conditional `?:`, so a
// branch may omit the name — here the `{..}` default is resolved from the
// `-> &point` result type flowing through the `?:`.
#[export = "pick"]
fn pick(c: i32) -> &point {
    c ? {..} : {x: 1, y: 2};
}
```

## Inferring Block Result Types

### Wax

A block's result type — `=> T` on an `if`, or the type after `do` (and likewise
`loop`, `try`, and `try_table`) — may be omitted where it is fixed by the values
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
    let sum: i32;
    let i: i32;
    let len: i32;
    sum = 0;
    i = 0;
    len = arr.length();
    'loop: loop {
        if i >=s len {
            return sum;
        }
        sum = sum + arr[i] as i32_u;
        i = i + 1;
        br 'loop;
    }
    unreachable;
}

#[export = "fill_bytes"]
fn fill_bytes(arr: &bytes, val: i32) {
    let i: i32;
    let len: i32;
    i = 0;
    len = arr.length();
    'loop: loop {
        if i >=s len {
            return;
        }
        arr[i] = val;
        i = i + 1;
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
        throw divide_by_zero;
    }
    a /s b;
}

#[export = "try_divide"]
fn try_divide(a: i32, b: i32) -> i32 {
    'on_error: do {
        try {
            return safe_divide(a, b);
        } catch [divide_by_zero -> 'on_error]
    }
    0;   // Return 0 on division by zero
}
```

## Recursive Types (Linked List)

### Wax

```wax
type list = { value: i32, next: &?list };

#[export = "make_node"]
fn make_node(value: i32, next: &?list) -> &list {
    {list| value: value, next: next};
}

#[export = "sum_list"]
fn sum_list(head: &?list) -> i32 {
    if !head {
        return 0;
    }
    let n: &list;
    n = head!;
    n.value + sum_list(n.next);
}
```

## Imports and Exports

### Wax

```wax
// Import a function from the host environment
#[import = ("env", "log")]
fn log(value: i32);

// Import a global
#[import = ("env", "base_value")]
const base_value: i32;

// Export a function that uses the imports
#[export = "compute_and_log"]
fn compute_and_log(x: i32) -> i32 {
    let result: i32;
    result = x + base_value;
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
    h = h ^ h >>u 16;
    h = h * 0x85ebca6b;
    h = h ^ h >>u 13;
    h = h * 0xc2b2ae35;
    h ^ h >>u 16;
}
```

## Strings and Characters

A character literal is an `i32` code point; a string literal builds a byte array
(`[mut i8]` by default, or a named array type with the `T # "…"` prefix). See
[Strings](language.md#strings).

### Wax

```wax
type chars = [i8];

#[export = "newline"]
fn newline() -> i32 {
    '\n';                       // 10
}

#[export = "greeting"]
fn greeting() -> &chars {
    chars # "hi\u{21}";         // the bytes 'h', 'i', '!'
}
```

### Equivalent WAT

`wax -f wat` keeps the literals as `(@char …)` / `(@string …)` annotations, so
they round-trip back to Wax unchanged:

```wat
(func $newline (export "newline") (result i32) (@char "\n"))

(func $greeting (export "greeting") (result (ref $chars))
  (@string $chars "hi!"))
```

In a WASM binary these lower to `i32.const 10` and an `array.new_fixed` of the
three bytes `104, 105, 33` — from which the character comes back as the integer
`10`, while the string is still recovered as `"hi!"` (its bytes are reasonable
UTF-8).

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

```wat
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

```wat
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

A struct can carry a *descriptor* — a second struct linked to it by reciprocal
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
    { descriptor({obj_desc| kind: kind})| x: x };
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
