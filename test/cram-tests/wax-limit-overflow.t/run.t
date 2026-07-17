An integer literal in a memory/table limit or a page size is converted to a
Uint64 while parsing (unlike an ordinary literal, which stays a string until
type-checking). A literal beyond the unsigned 64-bit range must be reported as a
recoverable syntax error, not crash the conversion — the check `wax check`, the
recovering `--all-errors`, and a plain conversion all reject it cleanly:

  $ cat > limit.wax <<'WAX'
  > memory m: i64 [577, 239903158239903158951737];
  > WAX

  $ wax check limit.wax
  Error: The integer literal 239903158239903158951737 is out of range.
   ──➤  limit.wax:1:21
  1 │ memory m: i64 [577, 239903158239903158951737];
    ·                     ^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Hint:
    This integer must fit in an unsigned 64-bit value (0 to
    18446744073709551615).
  [128]

Recovery (--all-errors) reaches the same conversion, so it too must report
rather than crash:

  $ wax check --all-errors limit.wax
  Error: The integer literal 239903158239903158951737 is out of range.
   ──➤  limit.wax:1:21
  1 │ memory m: i64 [577, 239903158239903158951737];
    ·                     ^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Hint:
    This integer must fit in an unsigned 64-bit value (0 to
    18446744073709551615).
  [128]

A page-size literal is converted the same way, and is likewise range-checked:

  $ cat > page.wax <<'WAX'
  > memory m: i32 [1] pagesize 999999999999999999999999;
  > WAX

  $ wax check page.wax
  Error: The integer literal 999999999999999999999999 is out of range.
   ──➤  page.wax:1:28
  1 │ memory m: i32 [1] pagesize 999999999999999999999999;
    ·                            ^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Hint:
    This integer must fit in an unsigned 64-bit value (0 to
    18446744073709551615).
  [128]

A limit within range is unaffected:

  $ cat > ok.wax <<'WAX'
  > memory m: i64 [577, 65536];
  > WAX

  $ wax check ok.wax
