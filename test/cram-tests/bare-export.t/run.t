A bare `#[export]` (no name) exports the field under its own Wax name, while
`#[export = "name"]` still exports under an explicit name.

  $ wax bare.wax -f wat
  (func $add (export "add") (param $a i32) (param $b i32) (result i32)
    (i32.add (local.get $a) (local.get $b))
  )
  
  (func $multiply (export "mul") (param $a i32) (param $b i32) (result i32)
    (i32.mul (local.get $a) (local.get $b))
  )
  
  (global $counter (export "counter") (mut i32) (i32.const 42))
  
  (memory $mem (export "mem") 1 1)




The bare form participates in duplicate-export detection under the reused name.

  $ wax check dup.wax
  Error: There is already an export of name "add".
   ──➤  dup.wax:4:12
  2 │ fn add(a: i32, b: i32) -> i32 { a + b; }
  3 │ 
  4 │ #[export = "add"]
    ·            ^^^^^
  5 │ fn other(a: i32) -> i32 { a; }
  6 │ 
  [128]

Converting Wasm back to Wax uses the short form when the export name matches the
field's Wax name, and the explicit form otherwise.

  $ wax bare.wax -f wat | wax -i wat -f wax
  #[export]
  fn add(a: i32, b: i32) -> i32 {
      a + b;
  }
  
  #[export = "mul"]
  fn multiply(a: i32, b: i32) -> i32 {
      a * b;
  }
  
  #[export]
  let counter = 42;
  
  #[export]
  memory mem: i32 [1, 1];
