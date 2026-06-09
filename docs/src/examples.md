# Examples

Complete examples demonstrating Wax features and their WebAssembly equivalents.

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
    len = arr.length;
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
    len = arr.length;
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
    len = arr.length;
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
