br_on_non_null delivers its non-null reference to the branch target. When that
target is a block whose result is left unwritten, the block takes its type from
its branches, and a br_on_non_null may be its only one. An operand known only
as a reference (`null!`, or a hole in unreachable code) used to reach the target
with nothing, so the block was inferred to return no value and the Wax the
decompiler printed for valid Wasm no longer compiled. It now delivers the
non-null bottom reference, as `br` does. Regression: bottom-fuzz (nightly).

  $ cat > bonn.wat <<'WAT'
  > (module
  >  (func (export "f")
  >    (block $b (result (ref null any))
  >      (ref.null any)
  >      (ref.as_non_null)
  >      (br_on_non_null $b)
  >      (unreachable))
  >    (drop)))
  > WAT

  $ wax -i wat -f wax bonn.wat -o bonn.wax && wax -i wax -f wasm bonn.wax -o /dev/null --validate

The same in Wax, with the operand `null!` and with a hole in unreachable code:

  $ cat > bonn-src.wax <<'WAX'
  > fn null_operand() { _ = 'b: do { br_on_non_null 'b null!; unreachable; }; }
  > fn dead_operand() { _ = 'b: do { unreachable; br_on_non_null 'b _; unreachable; }; }
  > WAX

  $ wax -f wat bonn-src.wax
  (func $null_operand
    (drop
      (block $b (result (ref none))
        (br_on_non_null $b (ref.as_non_null (ref.null none)))
        (unreachable)))
  )
  (func $dead_operand
    (drop
      (block $b (result (ref none))
        (unreachable)
        (br_on_non_null $b)
        (unreachable)))
  )
