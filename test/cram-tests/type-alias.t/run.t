A value-type alias names a value type: [(@type $t v)] defines it in WAT and
[(@type $t)] uses it wherever a value type is expected; Wax writes
[type t = v;] and a bare [t]. Defined under a conditional annotation, an alias
stands for a different type in each configuration, so code that only moves
such values around is written once.

Each configuration of the module is checked.

  $ wax check nativeint.wat

Resolving the conditional keeps the alias in text output, and expands it in
the binary format.

  $ wax -D portable_int=true -f wat nativeint.wat
  (@type $nativeint i64)
  (import "nativeint" "Nativeint_val"
    (func $Nativeint_val (param (ref eq)) (result (@type $nativeint)))
  )
  (import "nativeint" "caml_copy_nativeint"
    (func $caml_copy_nativeint (param (@type $nativeint)) (result (ref eq)))
  )
  (type $digits (array (mut (@type $nativeint))))
  (func $id (export "id") (param $v (ref eq)) (result (ref eq))
    (local $n (@type $nativeint))
    (local.set $n (call $Nativeint_val (local.get $v)))
    (call $caml_copy_nativeint (local.get $n))
  )
  (func $digit (export "digit") (param $d (ref $digits)) (result (ref eq))
    (call $caml_copy_nativeint (array.get $digits (local.get $d) (i32.const 0)))
  )
  $ wax -D portable_int=false -f wasm nativeint.wat -o nativeint.wasm
  $ wax -f wat nativeint.wasm
  (type $digits (array (mut i32)))
  (type (func (param (ref eq)) (result i32)))
  (type (func (param i32) (result (ref eq))))
  (type (func (param (ref eq)) (result (ref eq))))
  (type (func (param (ref $digits)) (result (ref eq))))
  (import "nativeint" "Nativeint_val"
    (func $Nativeint_val (param (ref eq)) (result i32))
  )
  (import "nativeint" "caml_copy_nativeint"
    (func $caml_copy_nativeint (param i32) (result (ref eq)))
  )
  (func $id (param $v (ref eq)) (result (ref eq))
    (local $n i32)
    local.get $v
    call $Nativeint_val
    local.set $n
    local.get $n
    call $caml_copy_nativeint
  )
  (func $digit (param $d (ref $digits)) (result (ref eq))
    local.get $d
    i32.const 0
    array.get $digits
    call $caml_copy_nativeint
  )
  (export "id" (func $id))
  (export "digit" (func $digit))

Desugaring expands the aliases into plain WebAssembly text.

  $ wax -D portable_int=true --desugar -f wat nativeint.wat
  (import "nativeint" "Nativeint_val"
    (func $Nativeint_val (param (ref eq)) (result i64))
  )
  (import "nativeint" "caml_copy_nativeint"
    (func $caml_copy_nativeint (param i64) (result (ref eq)))
  )
  (type $digits (array (mut i64)))
  (func $id (export "id") (param $v (ref eq)) (result (ref eq))
    (local $n i64)
    (local.set $n (call $Nativeint_val (local.get $v)))
    (call $caml_copy_nativeint (local.get $n))
  )
  (func $digit (export "digit") (param $d (ref $digits)) (result (ref eq))
    (call $caml_copy_nativeint (array.get $digits (local.get $d) (i32.const 0)))
  )

A conditional alias has no single expansion, so desugaring needs -D.

  $ wax --desugar -f wat nativeint.wat
  Error: A conditional annotation cannot be desugared to plain WebAssembly text.
   ──➤  nativeint.wat:2:3
  1 │ (module
  2 │   (@if $portable_int
    · ╭─^
  3 │    (@then (@type $nativeint i64))
    · │
  4 │    (@else (@type $nativeint i32)))
    · ╰────────────────────────────────^
  5 │   (import "nativeint" "Nativeint_val"
  6 │     (func $Nativeint_val (param (ref eq)) (result (@type $nativeint))))
  Hint: Resolve the conditionals with -D/--define.
  [128]

WAT and Wax round-trip with their aliases, conditional ones included: Wax
declares an alias-typed local with its alias, keeping it valid in every
configuration.

  $ wax -f wax nativeint.wat | tee nativeint.wax
  #[if(portable_int)]
  {
      type nativeint = i64;
  }
  #[else]
  {
      type nativeint = i32;
  }
  import "nativeint" {
      fn Nativeint_val(&eq) -> nativeint;
      fn caml_copy_nativeint(nativeint) -> &eq;
  }
  type digits = [mut nativeint];
  #[export]
  fn id(v: &eq) -> &eq {
      let n: nativeint = Nativeint_val(v);
      caml_copy_nativeint(n);
  }
  #[export]
  fn digit(d: &digits) -> &eq {
      caml_copy_nativeint(d[0]);
  }
  $ wax -f wat nativeint.wax
  (@if $portable_int
    (@then (@type $nativeint i64))
    (@else (@type $nativeint i32))
  )
  (import "nativeint" "Nativeint_val"
    (func $Nativeint_val (param (ref eq)) (result (@type $nativeint)))
  )
  (import "nativeint" "caml_copy_nativeint"
    (func $caml_copy_nativeint (param (@type $nativeint)) (result (ref eq)))
  )
  (type $digits (array (mut (@type $nativeint))))
  (func $id (export "id") (param $v (ref eq)) (result (ref eq))
    (local $n (@type $nativeint))
    (local.set $n (call $Nativeint_val (local.get $v)))
    (call $caml_copy_nativeint (local.get $n))
  )
  (func $digit (export "digit") (param $d (ref $digits)) (result (ref eq))
    (call $caml_copy_nativeint (array.get $digits (local.get $d) (i32.const 0)))
  )

An alias may stand for reference types of different hierarchies, here an
[externref] or a reference to a byte array, and be used as a struct field or a
parameter, the code specific to one representation going under the
conditional.

  $ wax check strings.wat
  $ wax -f wax strings.wat | tee strings.wax
  type bytes = [mut i8];
  #[if(use_js_string)]
  {
      type str = &?extern;
  }
  #[else]
  {
      type str = &bytes;
  }
  type custom_operations = { id: str, len: i32 };
  #[if(use_js_string)]
  {
      import "js"
      #[import = "length"]
      fn str_length(&?extern) -> i32;
  }
  #[else]
  {
      fn str_length(s: &bytes) -> i32 {
          s.length();
      }
  }
  #[export]
  fn ops_length(o: &custom_operations) -> i32 {
      str_length(o.id);
  }
  fn nat(x: str) -> i32 {
      #[if(use_js_string)]
      {
          return !x;
      }
      #[else]
      {
          return x.length();
      }
  }
  $ wax -f wat strings.wax -o strings-rt.wat
  $ wax check strings-rt.wat
  $ wax -D use_js_string=true -f wasm strings.wat -o strings.wasm
  $ wax -f wat strings.wasm
  (type $bytes (array (mut i8)))
  (type $custom_operations (struct (field $id externref) (field $len i32)))
  (type (func (param externref) (result i32)))
  (type (func (param (ref $custom_operations)) (result i32)))
  (import "js" "length" (func $str_length (param externref) (result i32)))
  (func $ops_length (param $o (ref $custom_operations)) (result i32)
    local.get $o
    struct.get $custom_operations $id
    call $str_length
  )
  (func $nat (param $x externref) (result i32)
    local.get $x
    ref.is_null
    return
  )
  (export "ops_length" (func $ops_length))

A select typed with an alias keeps that type as an ascription in Wax: the
alias stands for a number in one configuration and a reference in the other.

  $ wax -f wax select.wat | tee select.wax
  #[if(p)]
  {
      type n = i64;
  }
  #[else]
  {
      type n = &?s;
  }
  type s = { f: mut n };
  #[export]
  fn f(x: n, y: n, c: i32) -> n {
      let l: n =
          do n {
              x;
          };
      (c?l:y : n);
  }
  $ wax -f wat select.wax
  (@if $p (@then (@type $n i64)) (@else (@type $n (ref null $s))))
  (type $s (struct (field $f (mut (@type $n)))))
  (func $f (export "f")
    (param $x (@type $n)) (param $y (@type $n)) (param $c i32)
    (result (@type $n))
    (local $l (@type $n))
    (local.set $l (block (result (@type $n)) (local.get $x)))
    (select (result (@type $n)) (local.get $l) (local.get $y) (local.get $c))
  )

Errors in alias definitions are reported once, at the definition.

  $ wax check errors.wat
  Error: Unknown type: index '$missing' is not bound.
    ──➤  errors.wat:8:20
   6 │   (@type $c1 (@type $c2))
   7 │   (@type $c2 (@type $c1))
   8 │   (@type $bad (ref $missing))
     ·                    ^^^^^^^^
   9 │   (func (param (@type $nope)) (param (@type $c1)))
  10 │   (func (param (@type $bad)) (param (@type $bad))))
  Error: The type alias '$c1' is defined in terms of itself.
   ──➤  errors.wat:6:10
  4 │   (@type $a i64)
  5 │   (@type $t i32)
  6 │   (@type $c1 (@type $c2))
    ·          ^^^
  7 │   (@type $c2 (@type $c1))
  8 │   (@type $bad (ref $missing))
  Error: The type alias '$c2' is defined in terms of itself.
   ──➤  errors.wat:7:10
  5 │   (@type $t i32)
  6 │   (@type $c1 (@type $c2))
  7 │   (@type $c2 (@type $c1))
    ·          ^^^
  8 │   (@type $bad (ref $missing))
  9 │   (func (param (@type $nope)) (param (@type $c1)))
  Error: The type alias '$a' is already defined.
   ──➤  errors.wat:4:10
  1 │ (module
  2 │   (type $t (struct))
  3 │   (@type $a i32)
    ·          ^^ previously defined here
  4 │   (@type $a i64)
    ·          ^^
  5 │   (@type $t i32)
  6 │   (@type $c1 (@type $c2))
  Error: The type alias '$t' has the name of a type definition.
   ──➤  errors.wat:5:10
  1 │ (module
  2 │   (type $t (struct))
    ·         ^^ type defined here
  3 │   (@type $a i32)
  4 │   (@type $a i64)
  5 │   (@type $t i32)
    ·          ^^
  6 │   (@type $c1 (@type $c2))
  7 │   (@type $c2 (@type $c1))
  Error: Unknown type alias '$nope'.
    ──➤  errors.wat:9:23
   7 │   (@type $c2 (@type $c1))
   8 │   (@type $bad (ref $missing))
   9 │   (func (param (@type $nope)) (param (@type $c1)))
     ·                       ^^^^^
  10 │   (func (param (@type $bad)) (param (@type $bad))))
  11 │ 
  [128]
  $ wax check errors.wax
  Error: A type alias named 'a' is already bound.
   ──➤  errors.wax:3:6
  1 │ type t = {};
  2 │ type a = i32;
    ·      ^ previously bound here
  3 │ type a = i64;
    ·      ^
  4 │ type t = i32;
  5 │ type c1 = c2;
  Error: A type named 't' is already bound.
   ──➤  errors.wax:4:6
  1 │ type t = {};
    ·      ^ previously bound here
  2 │ type a = i32;
  3 │ type a = i64;
  4 │ type t = i32;
    ·      ^
  5 │ type c1 = c2;
  6 │ type c2 = c1;
  Error: 'i32' is a reserved built-in type name.
    ──➤  errors.wax:8:6
   6 │ type c2 = c1;
   7 │ type bad = &missing;
   8 │ type i32 = i64;
     ·      ^^^
   9 │ fn f(x: nope, y: c1, z: t) {}
  10 │ fn g(x: bad, y: bad) {}
  Error: The type 'missing' is not bound.
   ──➤  errors.wax:7:13
  5 │ type c1 = c2;
  6 │ type c2 = c1;
  7 │ type bad = &missing;
    ·             ^^^^^^^
  8 │ type i32 = i64;
  9 │ fn f(x: nope, y: c1, z: t) {}
  Error: The type alias 'c1' is defined in terms of itself.
   ──➤  errors.wax:5:6
  3 │ type a = i64;
  4 │ type t = i32;
  5 │ type c1 = c2;
    ·      ^^
  6 │ type c2 = c1;
  7 │ type bad = &missing;
  Error: The type alias 'c2' is defined in terms of itself.
   ──➤  errors.wax:6:6
  4 │ type t = i32;
  5 │ type c1 = c2;
  6 │ type c2 = c1;
    ·      ^^
  7 │ type bad = &missing;
  8 │ type i32 = i64;
  Error: 'nope' is not a value type or a type alias.
    ──➤  errors.wax:9:9
   7 │ type bad = &missing;
   8 │ type i32 = i64;
   9 │ fn f(x: nope, y: c1, z: t) {}
     ·         ^^^^
  10 │ fn g(x: bad, y: bad) {}
  11 │ 
  [128]

Discarding a cast to an alias is reported as discarding the cast to the type it
stands for, on both sides.

  $ wax check -W unused-result=warning discard.wax 2>&1 | grep Warning
  Warning [unused-result]:
  Warning [unused-result]:
  $ wax -f wat discard.wax -o discard.wat
  $ wax check -W unused-result=warning discard.wat 2>&1 | grep Warning
  Warning [unused-result]:
  Warning [unused-result]:

An alias may not take the name of a built-in type, a packed storage type or a
conversion target included: an alias [i8] would read back as the packed [i8].
A WAT alias with such a name is renamed on its way to Wax.

  $ wax check reserved.wax
  Error: 'i8' is a reserved built-in type name.
   ──➤  reserved.wax:1:6
  1 │ type i8 = i32;
    ·      ^^
  2 │ type i32_s = i64;
  3 │ 
  Error: 'i32_s' is a reserved built-in type name.
   ──➤  reserved.wax:2:6
  1 │ type i8 = i32;
  2 │ type i32_s = i64;
    ·      ^^^^^
  3 │ 
  [128]
  $ wax -f wax reserved.wat | tee reserved-rt.wax
  type i8_2 = i32;
  type s = { f: mut i8_2 };
  #[export]
  fn mk(x: i32) -> &s {
      { f: x };
  }
  $ wax -f wat reserved-rt.wax
  (@type $i8_2 i32)
  (type $s (struct (field $f (mut (@type $i8_2)))))
  (func $mk (export "mk") (param $x i32) (result (ref $s))
    (struct.new $s (local.get $x))
  )

An alias nothing reachable uses is reported, as an unused type is: one used
only by a function that never runs, or by a type nothing uses, is unused too.
The analysis is the same on both sides.

  $ wax check -W unused-field=warning unused.wax
  Warning [unused-field]: The type alias 'unused' is never used.
   ──➤  unused.wax:1:6
  1 │ type unused = i64;
    ·      ^^^^^^
  2 │ type _quiet = i64;
  3 │ type in_dead = i64;
  Warning [unused-field]: The type alias 'in_dead' is never used.
   ──➤  unused.wax:3:6
  1 │ type unused = i64;
  2 │ type _quiet = i64;
  3 │ type in_dead = i64;
    ·      ^^^^^^^
  4 │ type in_dead_type = i64;
  5 │ type via_chain = i32;
  Warning [unused-field]: The type alias 'in_dead_type' is never used.
   ──➤  unused.wax:4:6
  2 │ type _quiet = i64;
  3 │ type in_dead = i64;
  4 │ type in_dead_type = i64;
    ·      ^^^^^^^^^^^^
  5 │ type via_chain = i32;
  6 │ type chain = via_chain;
  Warning [unused-field]: The type 'dead_s' is never used.
    ──➤  unused.wax:8:6
   6 │ type chain = via_chain;
   7 │ type in_live = i64;
   8 │ type dead_s = { f: in_dead_type };
     ·      ^^^^^^
   9 │ fn dead(x: in_dead) {}
  10 │ #[export = "live"]
  Warning [unused-field]: The function 'dead' is never used.
    ──➤  unused.wax:9:4
   7 │ type in_live = i64;
   8 │ type dead_s = { f: in_dead_type };
   9 │ fn dead(x: in_dead) {}
     ·    ^^^^
  10 │ #[export = "live"]
  11 │ fn live(x: in_live, y: chain) {}
  $ wax -f wat unused.wax -o unused.wat
  $ wax check -W unused-field=warning unused.wat
  Warning [unused-field]: The function '$dead' is never used.
    ──➤  unused.wat:9:7
   7 │ (@type $in_live i64)
   8 │ (type $dead_s (struct (field $f (@type $in_dead_type))))
   9 │ (func $dead (param $x (@type $in_dead)))
     ·       ^^^^^
  10 │ (func $live (export "live")
  11 │   (param $x (@type $in_live)) (param $y (@type $chain))
  Warning [unused-field]: The type '$dead_s' is never used.
    ──➤  unused.wat:8:1
   6 │ (@type $chain (@type $via_chain))
   7 │ (@type $in_live i64)
   8 │ (type $dead_s (struct (field $f (@type $in_dead_type))))
     · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   9 │ (func $dead (param $x (@type $in_dead)))
  10 │ (func $live (export "live")
  Warning [unused-field]: The type alias '$unused' is never used.
   ──➤  unused.wat:1:8
  1 │ (@type $unused i64)
    ·        ^^^^^^^
  2 │ (@type $_quiet i64)
  3 │ (@type $in_dead i64)
  Warning [unused-field]: The type alias '$in_dead' is never used.
   ──➤  unused.wat:3:8
  1 │ (@type $unused i64)
  2 │ (@type $_quiet i64)
  3 │ (@type $in_dead i64)
    ·        ^^^^^^^^
  4 │ (@type $in_dead_type i64)
  5 │ (@type $via_chain i32)
  Warning [unused-field]: The type alias '$in_dead_type' is never used.
   ──➤  unused.wat:4:8
  2 │ (@type $_quiet i64)
  3 │ (@type $in_dead i64)
  4 │ (@type $in_dead_type i64)
    ·        ^^^^^^^^^^^^^
  5 │ (@type $via_chain i32)
  6 │ (@type $chain (@type $via_chain))

An alias is expanded where it is used: one used in a type defined before the
type it names is an error there.

  $ wax check forward.wat
  Error: Unknown type: index '$t' is not bound.
   ──➤  forward.wat:3:34
  1 │ (module
  2 │   (@type $r (ref null $t))
    ·                       ^^ in the type alias definition
  3 │   (type $s (struct (field (@type $r))))
    ·                                  ^^
  4 │   (type $t (struct))
  5 │   (func (export "f") (param (@type $r))))
  [128]
  $ wax check forward.wax
  Error: The type 't' is not bound.
   ──➤  forward.wax:2:15
  1 │ type r = &?t;
    ·            ^ in the type alias definition
  2 │ type s = { f: r };
    ·               ^
  3 │ type t = {};
  4 │ #[export = "f"]
  Error: 't' is not a value type or a type alias.
   ──➤  forward.wax:5:15
  3 │ type t = {};
  4 │ #[export = "f"]
  5 │ fn f(x: r, y: t) {}
    ·               ^
  6 │ 
  Hint: A reference to type 't' is written '&t'.
  [128]

A value read from a declaration written with an alias has the alias's type,
so a local, a global or a block result inferred from it is declared with the
alias, and has the right type in every configuration.

  $ wax -f wat inferred.wax
  (@if $portable_int
    (@then (@type $nativeint i64))
    (@else (@type $nativeint i32))
  )
  (import "nativeint" "Nativeint_val"
    (func $Nativeint_val (param $v (ref eq)) (result (@type $nativeint)))
  )
  (import "nativeint" "caml_copy_nativeint"
    (func $caml_copy_nativeint (param $n (@type $nativeint)) (result (ref eq)))
  )
  (import "nativeint" "zero" (global $zero (@type $nativeint)))
  (type $cell (struct (field $v (mut (@type $nativeint)))))
  (type $digits (array (mut (@type $nativeint))))
  (global $z (@type $nativeint) (global.get $zero))
  (func $copy (export "copy") (param $v (ref eq)) (result (ref eq))
    (local $n (@type $nativeint))
    (local.set $n (call $Nativeint_val (local.get $v)))
    (return (call $caml_copy_nativeint (local.get $n)))
  )
  (func $field (export "field")
    (param $c (ref $cell)) (param $d (ref $digits)) (result (ref eq))
    (local $x (@type $nativeint)) (local $y (@type $nativeint))
    (local $b (@type $nativeint))
    (local.set $x (struct.get $cell $v (local.get $c)))
    (local.set $y (array.get $digits (local.get $d) (i32.const 0)))
    (local.set $b (block (result (@type $nativeint)) (local.get $x)))
    (struct.set $cell $v (local.get $c) (local.get $y))
    (return (call $caml_copy_nativeint (local.get $b)))
  )

Two values of the same alias's type join at that type, in a conditional
expression or at a block's exits. A select of an alias's type lowers to a
select of that type, and a cast to an alias of a value of that type is the
identity, which lowers to nothing.

  $ wax -f wat joins.wax
  (@if $p
    (@then (@type $n i64) (@type $r externref))
    (@else (@type $n i32) (@type $r anyref))
  )
  (import "m" "get" (func $get (result (@type $n))))
  (import "m" "getr" (func $getr (result (@type $r))))
  (func $f (export "f")
    (param $c i32) (param $a (@type $n)) (param $b (@type $n))
    (param $x (@type $r))
    (local $s (@type $n)) (local $t (@type $n)) (local $w (@type $n))
    (local $v (@type $r)) (local $z (@type $r))
    (local.set $s
      (select (result (@type $n)) (local.get $a) (local.get $b) (local.get $c)))
    (local.set $t
      (if (result (@type $n)) (local.get $c)
        (then (local.get $a))
        (else (local.get $b))))
    (local.set $w
      (block $l (result (@type $n))
        (if (local.get $c) (then (br $l (local.get $a))))
        (local.get $b)))
    (local.set $v (local.get $x))
    (local.set $z
      (select (result (@type $r)) (local.get $x) (call $getr) (local.get $c)))
  )

The locals of a multi-value binding, and the result of a block operand left
unwritten, take the aliases of the types they are inferred from too.

  $ wax -f wat operands.wax
  (@if $p (@then (@type $n i64)) (@else (@type $n i32)))
  (type $ft (func (param (@type $n))))
  (type $k (cont $ft))
  (import "m" "two" (func $two (result (@type $n) (@type $n))))
  (func $f (export "f") (param $c (ref $k)) (param $a (@type $n))
    (local $y (@type $n)) (local $x (@type $n))
    (call $two)
    (local.set $y)
    (local.set $x)
    (resume $k (block (result (@type $n)) (local.get $a)) (local.get $c))
  )

A declared type written with an alias is still the type a function of the
same signature reuses: the global's type is [$t], not a new function type.

  $ wax -f wat reuse.wax
  (@type $word i32)
  (type $t (func (result (@type $word))))
  (func $get (result (@type $word)) (i32.const 42))
  (global $f (export "f") (ref $t) (ref.func $get))

An alias defined as a conditional one is conditional too, and a select whose
type is given by its context (a returned value) lowers like any other.

  $ wax -f wat chain.wax
  (@if $p (@then (@type $n i32)) (@else (@type $n eqref)))
  (@type $m (@type $n))
  (func $sel (export "sel")
    (param $a (@type $m)) (param $b (@type $m)) (param $c i32)
    (result (@type $m))
    (return
      (select (result (@type $m)) (local.get $a) (local.get $b) (local.get $c)))
  )
  (func $sel2 (export "sel2")
    (param $a (@type $n)) (param $b (@type $n)) (param $c i32)
    (result (@type $n))
    (return
      (select (result (@type $n)) (local.get $a) (local.get $b) (local.get $c)))
  )

A type is reused only where it is the same type in every configuration: a cast
to [&fn() -> i64] does not reuse a [fn() -> n] whose [n] is [i64] in one
configuration only, and a function's own type keeps the alias it is written
with.

  $ wax -f wat reuse-cast.wax
  (@if $p (@then (@type $n i64)) (@else (@type $n i32)))
  (type $t (func (result (@type $n))))
  (func $c (export "c") (param $x (ref func)) (result (ref func))
    (return (ref.cast (ref $"<fn:->I;>") (local.get $x)))
  )
  (func $h (export "h") (param $x (ref $t)) (result (ref $t))
    (return (local.get $x))
  )
  (type $"<fn:->I;>" (func (result i64)))
  $ wax -f wat reuse-func.wax
  (@if $p (@then (@type $word i64)) (@else (@type $word i32)))
  (func $get (result (@type $word))
    (@if $p (@then (return (i64.const 1))) (@else (return (i32.const 1))))
  )
  (global $f (export "f") (ref $<func:get>) (ref.func $get))
  (type $<func:get> (func (result (@type $word))))

An inline function type written with a conditional alias is a type of its own,
not the one the alias stands for in the configuration typed.

  $ wax -f wat inline-fn.wax
  (@if $p (@then (@type $word i64)) (@else (@type $word i32)))
  (func $c1 (export "c1") (param $x (ref func)) (result (ref func))
    (return (ref.cast (ref $"<fn:->@word;>") (local.get $x)))
  )
  (func $c2 (export "c2") (param $x (ref func)) (result (ref func))
    (return (ref.cast (ref $"<fn:->I;>") (local.get $x)))
  )
  (type $"<fn:->@word;>" (func (result (@type $word))))
  (type $"<fn:->I;>" (func (result i64)))

A struct inheriting its supertype's fields with [..] inherits them as written,
aliases included.

  $ wax -f wat splice.wax
  (@if $p (@then (@type $n i64)) (@else (@type $n i32)))
  (type $base (sub (struct (field $f (mut (@type $n))))))
  (type $sub
    (sub final $base (struct (field $f (mut (@type $n))) (field $g i32)))
  )
  (func $rd (export "rd") (param $s (ref $sub)) (result (@type $n))
    (local $y (@type $n))
    (local.set $y (struct.get $sub $f (local.get $s)))
    (return (local.get $y))
  )

A cast to a conditional alias is an instruction that depends on the
configuration ([ref.cast eqref] in one, [ref.cast anyref] in the other). Each
configuration is fine, but the module converted as a whole cannot hold it.

  $ wax check cast.wax
  $ wax -f wat cast.wax
  Error:
    This cast to the type alias 'n' has no single WebAssembly form: the alias is
    defined under a conditional annotation.
    ──➤  cast.wax:11:12
   9 │ #[export]
  10 │ fn c(x: &?any) -> n {
  11 │     return x as n;
     ·            ^^^^^^
  12 │ }
  13 │ 
  Hint:
    Cast in the branches of a conditional, to the types the alias stands for, or
    resolve the conditionals with -D.
  [128]
  $ wax -D p=false -f wat cast.wax
  (@type $n anyref)
  (func $c (export "c") (param $x anyref) (result (@type $n))
    (return (ref.cast anyref (local.get $x)))
  )

Code whose lowering depends on the type an alias stands for, such as an
arithmetic operation, only lowers in a resolved configuration.

  $ wax check shared.wax
  $ wax -f wat shared.wax
  Error:
    Type mismatch: this produces a value of type '(@type $nativeint)', but type
    'i64' is expected.
   ──➤  shared.wax:4:12
  2 │ #[export = "succ"]
  3 │ fn succ(x: nativeint) -> nativeint {
  4 │     return x + 1;
    ·            ^
  5 │ }
  6 │ 
  Hint: reachable when not $portable_int
  [128]
  $ wax -D portable_int=false -f wat shared.wax
  (@type $nativeint i32)
  (func $succ (export "succ")
    (param $x (@type $nativeint)) (result (@type $nativeint))
    (return (i32.add (local.get $x) (i32.const 1)))
  )
