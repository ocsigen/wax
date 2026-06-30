The binary format encodes the abstract reference types in two ways: a one-byte
shorthand (e.g. 0x69 for the nullable `exnref`) and the general `ref null <ht>`
form (0x63 followed by the heap type). exnref.wasm uses the 0x69 shorthand for
both the parameter and the result; the binary reader must accept it.

  $ wax -i wasm -f wat exnref.wasm
  (type (func (param (ref null exn)) (result (ref null exn))))
  (func (param (ref null exn)) (result (ref null exn)) local.get 0)
