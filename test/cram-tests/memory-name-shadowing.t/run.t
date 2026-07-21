A memory or table name used as a method/index receiver (`mem.load(..)`,
`tab[..]`, `tab.size()`) is on the same footing as a bare `Get`: Wax resolves a
bare name to a local first (globals, functions, memories and tables share one
namespace, so only a local can collide). So a local of the same name shadows the
memory/table, and decompilation must avoid generating such a collision.

When decompiling Wasm, a local that would collide with a memory/table name is
renamed, so the memory receiver is never shadowed (here the param `$x` collides
with memory `$x` and is renamed; `x.load32` still names the memory):

  $ cat > collide.wat <<'WAT'
  > (module
  >   (memory $x 1)
  >   (func (export "f") (param $x i32) (result i32)
  >     (i32.load $x (local.get $x))))
  > WAT

  $ wax -i wat -f wax collide.wat
  memory x: i32 [1];
  #[export]
  fn f(x_2: i32) -> i32 {
      x.load32(x_2);
  }

  $ wax -i wat -f wax collide.wat -o collide.wax && wax -i wax -f wasm collide.wax -o /dev/null --validate

In hand-written Wax, a local does shadow the memory: `m.load32` then resolves
against the local (an `i32`, with no such field) rather than the memory, instead
of silently using the memory behind the local's back:

  $ cat > shadow.wax <<'EOF'
  > memory m: i32 [1];
  > fn f() -> i32 {
  >     let m: i32 = 0;
  >     m.load32(0);
  > }
  > EOF

  $ wax check shadow.wax
  Error: Expected struct.
   ──➤  shadow.wax:4:5
  2 │ fn f() -> i32 {
  3 │     let m: i32 = 0;
  4 │     m.load32(0);
    ·     ^
  5 │ }
  6 │ 
  [128]
