Like `memory.init` and `data.drop`, the GC instruction `array.new_data`
references a data segment. The data section follows the code section in the
binary, so its length must be declared ahead of time by a data count section;
a module that uses `array.new_data` without one is malformed and must be
rejected at decode time (matching the reference interpreter and wasm-tools).
Regression: found by the vendored wasm-tools test corpus (gc/invalid.wast).

  $ wax -i wasm -f wat no-datacount.wasm
  File "no-datacount.wasm", line 1, characters 32-32:
  Error: data count section required
  [128]
