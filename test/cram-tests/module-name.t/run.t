A whole `.wax` file is a module; a `#![module = "..."]` inner attribute names
it. The name maps to the WebAssembly module name (the `$name` in a WAT
`(module $name …)`, stored in the `name` custom section), and survives every
conversion direction.

A named Wax module carries its name into WAT:

  $ cat > named.wax <<'EOF'
  > #![module = "mymod"]
  > 
  > #[export = "f"]
  > fn f() -> i32 {
  >     1;
  > }
  > EOF

  $ wax -i wax -f wat named.wax
  (module $mymod
  
    (func $f (export "f") (result i32) (i32.const 1))
  )

The attribute round-trips through a wax -> wax reprint:

  $ wax -i wax -f wax named.wax
  #![module = "mymod"]
  
  #[export = "f"]
  fn f() -> i32 {
      1;
  }


A WAT module name decompiles to the inner attribute:

  $ cat > named.wat <<'EOF'
  > (module $fromwat
  >   (func $g (export "g") (result i32)
  >     i32.const 2))
  > EOF

  $ wax -i wat -f wax named.wat
  #![module = "fromwat"]
  #[export]
  fn g() -> i32 {
      2;
  }

The name also survives a round-trip through the binary format:

  $ wax -i wax -f wasm named.wax -o named.wasm
  $ wax -i wasm -f wax named.wasm
  #![module = "mymod"]
  type t = fn() -> i32;
  #[export]
  fn f() -> i32 {
      1;
  }

The `module` annotation must be a string:

  $ printf '#![module = 42]\nfn f() {}\n' > bad-value.wax
  $ wax -i wax -f wat bad-value.wax --validate
  Error: The module annotation expects a string.
   ──➤  bad-value.wax:1:13
  1 │ #![module = 42]
    ·             ^^
  2 │ fn f() {}
  3 │ 
  [128]

A module may carry at most one name:

  $ printf '#![module = "a"]\n#![module = "b"]\nfn f() {}\n' > dup.wax
  $ wax -i wax -f wat dup.wax --validate
  Error: A module can have at most one name annotation.
   ──➤  dup.wax:2:1
  1 │ #![module = "a"]
    · ^^^^^^^^^^^^^^^^ other name annotation here
  2 │ #![module = "b"]
    · ^^^^^^^^^^^^^^^^
  3 │ fn f() {}
  4 │ 
  [128]

`module` is an inner attribute only; the outer `#[module = …]` form is rejected:

  $ printf '#[module = "x"]\nfn f() {}\n' > outer.wax
  $ wax -i wax -f wat outer.wax --validate
  Error: The module annotation is not allowed here.
   ──➤  outer.wax:1:12
  1 │ #[module = "x"]
    ·            ^^^
  2 │ fn f() {}
  3 │ 
  [128]

Conversely, the field-level attributes are rejected as inner attributes:

  $ printf '#![export = "x"]\nfn f() {}\n' > inner-export.wax
  $ wax -i wax -f wat inner-export.wax --validate
  Error: The export annotation is not allowed here.
   ──➤  inner-export.wax:1:13
  1 │ #![export = "x"]
    ·             ^^^
  2 │ fn f() {}
  3 │ 
  [128]

The module name applies in every configuration, so it must not sit inside a
conditional (its guard would otherwise be silently dropped) — rejected the same
way as a misplaced `#![feature]`:

  $ printf '#[if(FOO)] {\n  #![module = "m"]\n}\nfn f() {}\n' > cond.wax
  $ wax -i wax -f wat cond.wax --validate
  Error:
    A '#![module = "…"]' name annotation applies to the whole module and must
    appear at the top level, not inside a conditional.
   ──➤  cond.wax:2:15
  1 │ #[if(FOO)] {
  2 │   #![module = "m"]
    ·               ^^^
  3 │ }
  4 │ fn f() {}
  [128]
