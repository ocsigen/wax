An exact function import (the custom-descriptors proposal) declares that the
imported function has exactly the given type, so [ref.func] on it yields an
exact reference. Wax marks it with [!]: [fn g: !ft] for a named type, or
[fn h!(..)] for an inline signature. It maps to the WAT [(func (exact <type>))]
import form (binary import kind [0x20]).

  $ wax --validate -X custom-descriptors exact.wax -f wat
  (type $ft (func (param i32) (result i64)))
  
  ;; An exact function import: `ref.func` on it yields an exact reference. The
  ;; `!` marks the type exact, mirroring `&!t`. A named type uses `: !ft`; an
  ;; inline signature marks the name (`fn h!(...)`).
  (import "env" "g" (func $g (exact (type $ft))))
  
  (import "env" "h" (func $h (exact (param i32) (result i64))))



A WAT module using an exact function import decompiles back to the [!] form.

  $ wax -X custom-descriptors roundtrip.wat -f wax
  type ft = fn(i32) -> i64;
  #[import = ("env", "g")]
  fn g_2: !ft ;
  const g = g_2;

It survives a binary round-trip.

  $ wax -X custom-descriptors exact.wax -f wasm -o exact.wasm
  $ wax -X custom-descriptors exact.wasm -f wat
  (type $ft (func (param i32) (result i64)))
  (import "env" "g" (func $g (exact (param i32) (result i64))))
  (import "env" "h" (func $h (exact (param i32) (result i64))))
