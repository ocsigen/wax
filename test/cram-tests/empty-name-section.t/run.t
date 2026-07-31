The `name` custom section is a hint, and nothing stops it naming an entity the
EMPTY string — `empty-names.wasm` does exactly that for a type, a function and a
parameter, and both wasm-tools and wax accept the binary. But `$""` is not valid
text: the quoted `$"…"` form carries a merely awkward name (spaces, escapes,
non-ASCII), not an absent one. Printing it produced WAT that neither wasm-tools
nor wax's own parser could read back — wax accepting a binary and emitting
unreadable text, caught by the fuzzer's text-emitter and validation-parity
oracles. An empty name is dropped, and the index stands in its place:

  $ wax empty-names.wasm -f wat
  (type (func (param i32)))
  (func (param i32) (local i32))

It reads back, which is the property that was broken:

  $ wax empty-names.wasm -f wat -o out.wat
  $ wax check -W unused=hidden out.wat

The wax surface was never affected: it claims a source name only when it is a
valid identifier, so it had already generated its own.

  $ wax empty-names.wasm -f wax -W unused=hidden
  type t = fn(i32);
  fn f(i32) {
      let x: i32;
  }

A name that is merely awkward is still preserved, in the quoted form — only the
empty one is unrenderable:

  $ cat > quoted.wat <<'WAT'
  > (module (func $"a b" (param i32)))
  > WAT
  $ wax quoted.wat -f wasm -o quoted.wasm && wax quoted.wasm -f wat -W unused=hidden
  (type (func (param i32)))
  (func $"a b" (param i32))
