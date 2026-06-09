# Instructions

Wax instructions are expression-oriented.

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
| `f32.abs` ... `f64.sqrt` | `val.abs`, `val.neg`, `val.ceil`, `val.floor`, `val.trunc`, `val.nearest`, `val.sqrt` |
| `f32.min` ... `f64.copysign` | `min(v1, v2)`, `max(v1, v2)`, `copysign(v1, v2)` |

### Advanced Integer Operations

| Wasm | Wax |
|---|---|
| `i32.clz` ... `i64.popcnt` | `val.clz`, `val.ctz`, `val.popcnt` |
| `i32.rotl` ... `i64.rotr` | `rotl(v1, v2)`, `rotr(v1, v2)` |



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
| `i32.reinterpret_f32` | `val.to_bits` |
| `f32.reinterpret_i32` | `val.from_bits` |

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

## Control Instructions

| Wasm | Wax |
|------|-----|
| `block` | `do { ... }` or `{ ... }` |
| `loop` | `loop { ... }` |
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
| `array.get $t` | `arr[idx]` |
| `array.get_s $t` | `arr[idx] as i32_s` |
| `array.get_u $t` | `arr[idx] as i32_u` |
| `array.set $t` | `arr[idx] = val` |
| `array.len` | `arr.length` |



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

## Unsupported Features

The following WebAssembly features do not have dedicated Wax syntax. When converting from WAT/WASM to Wax, these instructions are preserved as-is or may be dropped:

*   **Linear Memory**: `memory.size`, `memory.grow`, `load`, `store` (all variants). Wax focuses on GC-based memory management using structs and arrays.
*   **Tables**: `table.get`, `table.set`, `call_indirect` (and related instructions). Use typed function references instead.
*   **SIMD**: All `v128` vector instructions. The `v128` type exists but operations are not exposed.
*   **Indirect Calls via Tables**: `return_call_indirect`, `call_indirect`. Use `call_ref` with function references instead.
