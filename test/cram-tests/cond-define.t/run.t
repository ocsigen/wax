The -D/--define option sets conditional-compilation variables: a fully
determined #[if(...)] is removed (its surviving branch spliced in), and a
partially determined one is kept with its condition simplified.

A boolean set to true selects the #[if] branch; the conditional disappears.

  $ wax -f wax -D debug=true def.wax
  const x: i32 = 1;
  
  #[if(ocaml_version >= (5, 1, 0))]
  const size: i32 = 16;
  #[else]
  const size: i32 = 20;
  
  #[if(target = "wasi")]
  const y: i32 = 3;

A boolean set to false selects the #[else] branch.

  $ wax -f wax -D debug=false def.wax
  const x: i32 = 2;
  
  #[if(ocaml_version >= (5, 1, 0))]
  const size: i32 = 16;
  #[else]
  const size: i32 = 20;

A version compares against a version literal.

  $ wax -f wax -D ocaml_version=5.1.0 def.wax
  #[if(debug)]
  const x: i32 = 1;
  #[else]
  const x: i32 = 2;
  
  const size: i32 = 16;
  
  #[if(all(debug, target = "wasi"))]
  const y: i32 = 3;

  $ wax -f wax -D ocaml_version=4.14.0 def.wax
  #[if(debug)]
  const x: i32 = 1;
  #[else]
  const x: i32 = 2;
  
  const size: i32 = 20;
  
  #[if(all(debug, target = "wasi"))]
  const y: i32 = 3;

Several variables can be set at once. Here every condition is determined.

  $ wax -f wax -D debug=true -D ocaml_version=5.1.0 -D target=wasi def.wax
  const x: i32 = 1;
  
  const size: i32 = 16;
  
  const y: i32 = 3;

Setting only some variables simplifies the rest: with debug=true the condition
all(debug, target = "wasi") reduces to target = "wasi".

  $ wax -f wax -D debug=true def.wax
  const x: i32 = 1;
  
  #[if(ocaml_version >= (5, 1, 0))]
  const size: i32 = 16;
  #[else]
  const size: i32 = 20;
  
  #[if(target = "wasi")]
  const y: i32 = 3;

With debug=false that whole conditional is removed.

  $ wax -f wax -D debug=false def.wax
  const x: i32 = 2;
  
  #[if(ocaml_version >= (5, 1, 0))]
  const size: i32 = 16;
  #[else]
  const size: i32 = 20;

Instruction-level conditionals are specialized too.

  $ wax -f wax -D debug=true instr.wax
  fn f() -> i32 {
      let x: i32;
      #[if(not(target = "wasm32"))]
      {
          x = 1;
      }
      #[else]
      {
          x = 2;
      }
      x;
  }

  $ wax -f wax -D debug=false instr.wax
  fn f() -> i32 { let x: i32; x = 2; x; }

The WAT path works the same way on (@if ...) annotations.

  $ wax -i wat -f wat -D ocaml_version=5.1.0 cond.wat
  (global $size i32 (i32.const 16))
  (func $get (result i32) (global.get $size))

  $ wax -i wat -f wat -D ocaml_version=4.14.0 cond.wat
  (global $size i32 (i32.const 20))
  (func $get (result i32) (global.get $size))

A bare name sets a boolean to true.

  $ wax -f wax -D debug instr.wax
  fn f() -> i32 {
      let x: i32;
      #[if(not(target = "wasm32"))]
      {
          x = 1;
      }
      #[else]
      {
          x = 2;
      }
      x;
  }

Setting a variable to a value of the wrong kind is an error.

  $ wax -f wax -D debug=5.1.0 def.wax
  Error:
    Variable $debug is set to a non-boolean value but used as a boolean here.
   ──➤  def.wax:1:6
  1 │ #[if(debug)]
    ·      ^^^^^
  2 │ const x: i32 = 1;
  3 │ #[else]
  [128]

An empty variable name is rejected.

  $ wax -f wax -D =oops def.wax
  Usage: wax [--help] [COMMAND] …
  wax: option -D: empty variable name
  [124]

Comments inside a removed branch are dropped, rather than re-attaching to a
surviving node; the surviving branch keeps its own comment.

  $ wax -f wax -D debug=true comments.wax
  // comment in the then-branch
  const x: i32 = 1;

  $ wax -f wax -D debug=false comments.wax
  // comment in the else-branch
  const x: i32 = 2;

With no -D, both branches and their comments are preserved.

  $ wax -f wax comments.wax
  #[if(debug)]
  // comment in the then-branch
  const x: i32 = 1;
  #[else]
  // comment in the else-branch
  const x: i32 = 2;
