# Instructions

Wax instructions are expression-oriented.

## Literals

A [character literal](../language.md#characters) is an `i32` constant (its
Unicode code point); a [string literal](../language.md#strings) builds a byte
array with `array.new_fixed`.

| Wasm | Wax |
|------|-----|
| `i32.const <code point>` | `'c'` |
| `array.new_fixed $t` (constant elements) | `"..."` or `t # "..."` |

In WAT both forms are written with annotations — `(@char …)` and `(@string …)`
— so they round-trip faithfully through WAT. A WASM binary keeps only the
underlying `i32.const` / `array.new_fixed`: a character decompiles to a plain
integer, and an `array.new_fixed` is recovered as a string only when its bytes
look like a reasonable UTF-8 string (valid UTF-8, no control characters other
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

## Control Instructions

| Wasm | Wax |
|------|-----|
| `block` | `do { ... }` or `{ ... }` |
| `loop` | `loop { ... }` |
| `loop` + leading back-`br` idiom | `while cond { ... }` |
| `loop` + trailing back-`br_if` idiom | `loop { ... br_if 'l cond; }` (kept as a plain loop) |
| `if ... else ...` | `if cond { ... } else { ... }` |
| `br $l` | `br 'l` |
| `br_if $l` | `br_if 'l cond` |
| `br_table $l* $ld` | `br_table ['l* else 'ld] val` |
| `br_on_null $l` | `br_on_null 'l val` |
| `br_on_non_null $l` | `br_on_non_null 'l val` |
| `br_on_cast $l $t1 $t2` | `br_on_cast 'l t2 val` |
| `br_on_cast_fail $l $t1 $t2` | `br_on_cast_fail 'l t2 val` |
| `return` | `return val` |
| `call $f` | `f(args)` |
| `call_ref $t` | `(val as &?t)(args)` |
| `return_call $f` | `become f(args)` |
| `return_call_ref $t` | `become (val as &?t)(args)` |
| `unreachable` | `unreachable` |
| `nop` | `nop` |
| `select` | `cond ? v1 : v2` |

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

## Reference Instructions

| Wasm | Wax |
|------|-----|
| `ref.null` | `null` |
| `ref.is_null` | `!val` |
| `ref.as_non_null` | `val!` |
| `ref.i31` | `val as &i31` |
| `i31.get_s` | `val as i32_s` |
| `i31.get_u` | `val as i32_u` |
| `ref.cast` | `val as &type` |
| `ref.test` | `val is &type` |

These casts can also chain through a forced intermediate, written as a single `as`:

- **`&ref as i32_s`/`as i32_u`** on a reference that is not already `&i31` (e.g. an `&any` or `&eq`) inserts a `ref.cast (ref i31)` before the `i31.get` — so it covers both `i31.get_s` and `ref.cast (ref i31)` + `i31.get_s`.
- **`&ref as i64_s`/`as i64_u`** widens that further: the `i31.get` (with the `ref.cast` above as needed) is followed by `i64.extend_i32_s`/`_u`.
- **`i64 as &i31`** wraps to `i32` (`i32.wrap_i64`) before `ref.i31`.
- **`extern_val as &T`** for an `any`-hierarchy `T` (e.g. a struct type) inserts `any.convert_extern` before the `ref.cast (ref T)`; likewise an `any`-hierarchy value `as &extern` uses `extern.convert_any`.
- **`i32_val as &extern`** boxes the `i32` with `ref.i31` before `extern.convert_any`.

## Aggregate Instructions

| Wasm | Wax |
|------|-----|
| `struct.new $t` | `{t\| field: val, ... }` |
| `struct.new_default $t` | `{t\| .. }` |
| `struct.get $t $f` | `val.field` |
| `struct.set $t $f` | `val.field = new_val` |
| `array.new $t` | `[t\| val; len]` |
| `array.new_default $t` | `[t\| ..; len]` |
| `array.new_fixed $t` | `[t\| val, ...]` |
| `array.new_data $t $d` | `[t\| d @ offset; count]` |
| `array.new_elem $t $e` | `[t\| e @ offset; count]` |
| `array.init_data $t $d` | `arr.init(d, dest, src, count)` |
| `array.init_elem $t $e` | `arr.init(e, dest, src, count)` |
| `array.get $t` | `arr[idx]` |
| `array.get_s $t` | `arr[idx] as i32_s` |
| `array.get_u $t` | `arr[idx] as i32_u` |
| `array.set $t` | `arr[idx] = val` |
| `array.len` | `arr.length()` |

A packed (`i8`/`i16`) struct field or array element read sign- or zero-extends to `i32` via the `as i32_s`/`as i32_u` cast, as shown above (`struct.get_s`/`_u`, `array.get_s`/`_u`). Widening straight to `i64` — `val.field as i64_s` or `arr[idx] as i64_u` — emits the packed read followed by `i64.extend_i32_s`/`_u`.

## Memory Access

Loads and stores are method calls on a [memory](module_fields.md#memories). The method name carries the access width; the value's signedness (for narrow loads) and its `i32`/`i64` type are expressed with the surrounding `as iN_s`/`as iN_u` cast, mirroring packed array access.

| Wax | Wasm |
|-----|------|
| `m.load32(p)` | `i32.load` |
| `m.load64(p)` | `i64.load` |
| `m.loadf32(p)` / `m.loadf64(p)` | `f32.load` / `f64.load` |
| `m.load8(p) as i32_s` | `i32.load8_s` |
| `m.load16(p) as i32_u` | `i32.load16_u` |
| `m.load32(p) as i64_s` | `i64.load32_s` |
| `m.load8(p) as i64_s` | `i64.load8_s` |
| `m.load16(p) as i64_u` | `i64.load16_u` |
| `m.store32(p, v)` | `i32.store` (`v: i32`) or `i64.store32` (`v: i64`) |
| `m.store16(p, v)` | `i32.store16` or `i64.store16` (by `v`'s type) |
| `m.store64(p, v)` / `m.storef64(p, v)` | `i64.store` / `f64.store` |

A bare narrow load (`m.load8(p)` with no cast) defaults to unsigned `i32`, like `array.get_u`. The store value's `i32`/`i64` type is inferred from the operand.

Two optional trailing arguments give the `align` and `offset` of the access (both constant integers); `offset` requires `align` to fill its positional slot:

```wax
m.load32(p);          // i32.load
m.load32(p, 1);       // i32.load align=1
m.load32(p, 1, 16);   // i32.load align=1 offset=16
```

The alignment defaults to the access's natural alignment and is only printed when it differs; the offset defaults to `0`.

The remaining memory operations are also methods on the memory (a data segment is named directly, not as a value):

| Wax | Wasm |
|-----|------|
| `m.size()` | `memory.size` |
| `m.grow(n)` | `memory.grow` |
| `m.fill(dest, val, len)` | `memory.fill` |
| `m.copy(dest, src, len)` | `memory.copy` (within `m`) |
| `m.copy(m2, dest, src, len)` | `memory.copy m m2` (copy from `m2` into `m`) |
| `m.init(seg, dest, src, len)` | `memory.init seg` |
| `seg.drop()` | `data.drop seg` |

## Table Access

A [table](module_fields.md#tables) is indexed like an array, and an indirect call is written as a call through a table slot cast to the callee's function type.

| Wasm | Wax |
|------|-----|
| `table.get $t` | `t[i]` |
| `table.set $t` | `t[i] = v` |
| `call_indirect $t (type $ft)` | `(t[i] as &ft)(args)` |
| `call_indirect $t (result i32)` | `(t[i] as &fn() -> i32)(args)` |
| `return_call_indirect $t (type $ft)` | `return (t[i] as &ft)(args)` |

`call_indirect` is reconstructed from this pattern on conversion to WAT/WASM, so it round-trips. The cast target names the callee's function type: either a defined type (`&ft`) or an inline one written `&fn(params) -> results` (used when the WAT type is anonymous). When the table's element type is already the concrete function type `&ft`, the cast may be omitted (`t[i](args)`).

The other table operations are methods on the table (an element segment is named directly):

| Wax | Wasm |
|-----|------|
| `t.size()` | `table.size` |
| `t.grow(val, n)` | `table.grow` |
| `t.fill(dest, val, len)` | `table.fill` |
| `t.copy(dest, src, len)` | `table.copy` (within `t`) |
| `t.copy(t2, dest, src, len)` | `table.copy t t2` (copy from `t2` into `t`) |
| `t.init(seg, dest, src, len)` | `table.init seg` |
| `seg.drop()` | `elem.drop seg` |

A GC array can also be filled from a segment with `arr.init(seg, dest, src, len)` (`array.init_data`/`array.init_elem`, selected by the array's element type) — the segment-from-array counterpart of [`array.new_data`/`array.new_elem`](#aggregate-instructions).

## Exception Instructions

| Wasm | Wax |
|------|-----|
| `throw $tag` | `throw tag(args)` |
| `throw_ref` | `throw_ref` |
| `try_table ... catch $tag $l ...` | `try { ... } catch [ tag -> 'l, ... ]` |
| `try_table ... catch_ref $tag $l ...` | `try { ... } catch [ tag & -> 'l, ... ]` |
| `try_table ... catch_all $l ...` | `try { ... } catch [ _ -> 'l, ... ]` |
| `try_table ... catch_all_ref $l ...` | `try { ... } catch [ _ & -> 'l, ... ]` |
| `try ... catch $tag ...` | `try { ... } catch { tag => { ... } ... }` |
| `try ... catch_all ...` | `try { ... } catch { _ => { ... } }` |

The `try { ... } catch [ ... ]` syntax compiles to WebAssembly's `try_table` instruction (the current standard). The `try { ... } catch { tag => { ... } }` syntax compiles to the older `try`/`catch` instructions (deprecated but still supported for compatibility).

## Stack Switching Instructions

These correspond to the WebAssembly [stack-switching proposal](https://github.com/WebAssembly/stack-switching). A continuation type is declared with `type k = cont ft;` (see [Types](types.md)); `<k>` and `<tag>` below are the names of a continuation type and a tag respectively.

| Wasm | Wax |
|------|-----|
| `cont.new $k` | `cont_new k (func)` |
| `cont.bind $k1 $k2` | `cont_bind k1 k2 (args, cont)` |
| `suspend $tag` | `suspend tag (args)` |
| `resume $k` | `resume k [] (args, cont)` |
| `resume $k (on $tag $l) ...` | `resume k [ tag -> 'l, ... ] (args, cont)` |
| `resume $k (on $tag switch) ...` | `resume k [ tag -> switch, ... ] (args, cont)` |
| `resume_throw $k $tag ...` | `resume_throw k tag [ ... ] (args, cont)` |
| `resume_throw_ref $k ...` | `resume_throw_ref k [ ... ] (exn, cont)` |
| `switch $k $tag` | `switch k tag (args, cont)` |

Operands are written in WebAssembly stack order, so the continuation reference is the last argument. The handler list in `[ ... ]` mirrors the `try ... catch [ ... ]` syntax: `tag -> 'l` is an `(on $tag $l)` clause and `tag -> switch` is an `(on $tag switch)` clause.

Tags used with `suspend`/`resume` may have result types (unlike exception tags); see [Tags](module_fields.md#tags). When a function reference is passed to `cont_new` for a continuation whose function type belongs to a recursion group, declare the function with an explicit type (`fn f: ft (...) { ... }`) so its type matches the continuation's.

## SIMD (Vector) Instructions

`v128` vector operations are written as method intrinsics with the lane shape baked into the name. The Wax name is the WebAssembly mnemonic with the leading shape moved to the end: `i32x4.add` becomes `add_i32x4`, `f32x4.sqrt` becomes `sqrt_f32x4`, and the whole-vector `v128.and` becomes `and_v128`. Signed/unsigned variants keep the `_s`/`_u` (`min_s_i8x16`, `extract_lane_u_i8x16`). Constant lane immediates (lane indices, shuffle indices) come first in the argument list, before any remaining stack operands.

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
| `v128.const i32x4 1 2 3 4` | `v128::const_i32x4(1, 2, 3, 4)` |
| `v128.const f32x4 1.5 2.5 3.5 4.5` | `v128::const_f32x4(1.5, 2.5, 3.5, 4.5)` |
| `v128.const i8x16 0 1 ... 15` | `v128::const_i8x16(0, 1, ..., 15)` |

Memory loads and stores are methods on a [memory](module_fields.md#memories), like the scalar accesses above (the optional trailing `align`/`offset` arguments work the same way):

| Wax | Wasm |
|-----|------|
| `m.v128_load(p)` | `v128.load` |
| `m.v128_store(p, v)` | `v128.store` |
| `m.v128_load8x8_s(p)` | `v128.load8x8_s` (and `16x4`/`32x2`, `_s`/`_u`) |
| `m.v128_load32_zero(p)` | `v128.load32_zero` (and `64_zero`) |
| `m.v128_load8_splat(p)` | `v128.load8_splat` (and `16`/`32`/`64`) |
| `m.v128_load8_lane(p, v, lane)` | `v128.load8_lane` (and `16`/`32`/`64`) |
| `m.v128_store8_lane(p, v, lane)` | `v128.store8_lane` (and `16`/`32`/`64`) |

Relaxed-SIMD operations follow the same scheme:

| Wasm | Wax |
|------|-----|
| `f32x4.relaxed_madd` | `a.relaxed_madd_f32x4(b, c)` |
| `i8x16.relaxed_swizzle` | `a.relaxed_swizzle_i8x16(b)` |

No intrinsic can clash with a module entity name: the free-function intrinsics are written as `v128::`/`i64::` qualified paths and every other is a method on a receiver, so a function may freely be named e.g. `v128_bitselect` without any renaming.
