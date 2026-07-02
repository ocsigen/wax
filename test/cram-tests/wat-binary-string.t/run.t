A string that is valid UTF-8 is printed readably, escaping only what a WAT
string literal cannot carry raw:

  $ cat > utf8.wat <<'EOF'
  > (module (memory 1) (data (i32.const 0) "\c3\a9 hi"))
  > EOF
  $ wax -i wat -f wat utf8.wat
  (memory 1)
  (data (i32.const 0) "é hi")

A string that is not valid UTF-8 is binary data, so every byte is dumped as a
\HH escape rather than interleaving decoded characters with byte escapes (here
a valid "é" is followed by the invalid byte 0xff):

  $ cat > bin.wat <<'EOF'
  > (module (memory 1) (data (i32.const 0) "\c3\a9\ff"))
  > EOF
  $ wax -i wat -f wat bin.wat
  (memory 1)
  (data (i32.const 0) "\c3\a9\ff")

Either way the bytes are preserved through a compile to binary and back:

  $ wax -i wat -f wasm bin.wat -o bin.wasm && wax -i wasm -f wat bin.wasm
  (memory 1)
  (data (offset i32.const 0) "\c3\a9\ff")
