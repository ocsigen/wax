Wax's WAT reader is lenient about the spec's `ref.func` declaration rule: a
function used by `ref.func` in a body need not appear in an `(elem declare …)`
segment. `--desugar` produces plain WebAssembly text, so it also synthesises the
missing declarative segment.

A conditional-compilation module compiled to WAT keeps its `(@if …)` and omits
the declare segment (that conditional WAT is Wax-only text). Resolving the
conditionals with `-D` and desugaring heals the hole: the `(ref.func $callee)`
now has a matching `(elem declare func $callee)`.

  $ wax -i wat ce.wat -D FOO=true --desugar -f wat
  (type $ft (func (result i32)))
  (func $h)
  (func $callee (result i32) (i32.const 42))
  (func $main (result (ref $ft)) (ref.func $callee))
  (elem declare func $callee)

The result passes strict reference validation (only unused-function warnings,
hidden here):

  $ wax -i wat ce.wat -D FOO=true --desugar -f wat -o healed.wat
  $ wax check -f wat -s -W unused=hidden healed.wat && echo ok
  ok

Without `--desugar` the segment is not added (the default WAT-to-WAT behaviour is
untouched):

  $ wax -i wat ce.wat -D FOO=true -f wat
  (type $ft (func (result i32)))
  (func $h)
  (func $callee (result i32) (i32.const 42))
  (func $main (result (ref $ft)) (ref.func $callee))

The wax-to-wat lowering already emits the segment on a conditional-free module,
so desugaring a fully specialised Wax input adds no duplicate — exactly one
declare segment:

  $ wax ce.wax -D FOO=true --desugar -f wat
  (type $ft (func (result i32)))
  (func $h)
  (func $callee (result i32) (i32.const 42))
  (func $main (result (ref $ft)) (ref.func $callee))
  (elem declare func $callee)

A function already declared as referenceable — here `$callee` is exported — is
left alone: no segment is synthesised.

  $ wax -i wat exported.wat --desugar -f wat
  (type $ft (func (result i32)))
  (func $callee (export "callee") (result i32) (i32.const 42))
  (func $main (result (ref $ft)) (ref.func $callee))
