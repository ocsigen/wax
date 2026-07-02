A \u{...} escape whose hexnum overflows an int is a clean "malformed" parse
error, not a crash (the lexer used to int_of_string it before the validity
check). Regression: found auditing literal-parsing paths.

  $ cat > big.wat <<'EOF'
  > (module (func (export "\u{ffffffffffffffff}")))
  > EOF
  $ wax -i wat -f wasm big.wat -o /dev/null
  Error: Malformed Unicode escape.
  
   ──➤  big.wat:1:24
  1 │ (module (func (export "\u{ffffffffffffffff}")))
    ·                        ^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

A valid escape still works:

  $ cat > ok.wat <<'EOF'
  > (module (func (export "\u{41}")))
  > EOF
  $ wax -i wat -f wat ok.wat | head -1
  (func (export "A"))
