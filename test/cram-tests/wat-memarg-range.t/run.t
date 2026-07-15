A WAT memory offset/alignment beyond u64 is a clean parse error, not a crash
(the parser used to call Uint64.of_string directly and raise). Regression: found
by auditing the literal-parsing paths after the wax-side fuzzer kept surfacing
out-of-range-immediate crashes.

  $ cat > big.wat <<'EOF'
  > (module (memory 1)
  >   (func (param i32) (result i32) (i32.load offset=99999999999999999999 (local.get 0))))
  > EOF
  $ wax -i wat -f wasm big.wat -o /dev/null
  Error: Constant 99999999999999999999 is out of range.
   ──➤  big.wat:2:44
  1 │ (module (memory 1)
  2 │   (func (param i32) (result i32) (i32.load offset=99999999999999999999 (local.get 0))))
    ·                                            ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ 
  [128]

A u64-max offset on an i64 memory is in range and accepted:

  $ cat > ok.wat <<'EOF'
  > (module (memory i64 1)
  >   (func (param i64) (result i32) (i32.load offset=18446744073709551615 (local.get 0))))
  > EOF
  $ wax -i wat -f wasm ok.wat -o /dev/null --validate
