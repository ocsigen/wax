A SIMD vector op written as a method (`_.not_v128()`) fixes its receiver's type
from the method name alone (`v128`), so the decompiler leaves the receiver hole
un-annotated. In dead code the hole is a polymorphic value taken off the
`unreachable` stack; the typer pins it to the receiver type the op requires, so
`To_wasm` sees a concrete `v128` and lowers the op. Before the receiver hole was
pinned it stayed type-less and `To_wasm` had to drop the whole method call to an
`unreachable`, losing the instruction.

  $ cat > t.wax <<'EOF'
  > #[export]
  > fn f() -> v128 {
  >     unreachable;
  >     _.not_v128().neg_i64x2();
  > }
  > EOF
  $ wax -i wax t.wax -f wat --validate -W dead-code=hidden
  (func $f (export "f") (result v128) (unreachable) (i64x2.neg (v128.not)))
