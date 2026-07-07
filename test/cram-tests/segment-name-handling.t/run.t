Data and element segment names are handled like memory/table names: in the same
namespace as globals (so they never collide with another module entity), never
shadowed by a generated local, and `seg.drop()` defers to a local of the same
name.

When decompiling, a local that would collide with a segment name is renamed, so
`data.drop` keeps naming the segment:

  $ cat > collide.wat <<'WAT'
  > (module
  >   (data $x "ab")
  >   (func (export "f") (param $x i32)
  >     (data.drop $x)
  >     (drop (local.get $x))))
  > WAT

  $ wax -i wat -f wax collide.wat
  data x = "ab";
  #[export]
  fn f(x_2: i32) {
      x.drop();
      _ = x_2;
  }

  $ wax -i wat -f wax collide.wat -o collide.wax && wax -i wax -f wasm collide.wax -o /dev/null --validate

A `.drop()` on a struct field of that name is an indirect call, not a segment
drop (the receiver is not a segment), so it lowers to `call_ref`:

  $ cat > field.wax <<'EOF'
  > type ft = fn();
  > type s = { drop: &ft };
  > #[export = "g"]
  > fn g(x: &s) {
  >     x.drop();
  > }
  > EOF

  $ wax -i wax -f wat field.wax --validate
  (type $ft (func))
  (type $s (struct (field $drop (ref $ft))))
  (func $g (export "g") (param $x (ref $s))
    (call_ref $ft (struct.get $s $drop (local.get $x)))
  )
