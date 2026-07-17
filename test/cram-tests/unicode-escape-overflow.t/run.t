A `\u{…}` escape whose value overflows a native int (or is otherwise out of the
Unicode scalar range) is a clean "malformed" error, not a crash:

  $ wax big.wax -f wat
  Error: Malformed Unicode escape.
   ──➤  big.wax:1:17
  1 │ fn a() -> i32 { '\u{FFFFFFFFFFFFFF}'; }
    ·                 ^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Hint:
    A Unicode escape has the form '\u{XXXX}', where 'XXXX' is the hexadecimal
    code of a Unicode scalar value.
  [128]

