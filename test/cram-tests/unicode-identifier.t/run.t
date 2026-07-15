Identifiers may contain Unicode letters. They are lexed by a coarse rule and
then validated against the Unicode XID properties (see Wax_utils.Xid), which
keeps the large XID character classes out of the lexer's DFA. A valid Unicode
identifier round-trips (WAT quotes it, as it is not a bare WAT identifier):

  $ wax ok.wax -f wat
  (func $"café" (result i32) (i32.const 1))
  (func $"λ" (result i32) (i32.const 2))

A character that is not an identifier character (here an emoji, which is not
XID_Continue) is rejected with the ordinary "unexpected character" error and
exit code 128 — the same message and location as any stray character:

  $ wax check bad.wax
  Error: Unexpected character '😀'.
   ──➤  bad.wax:1:5
  1 │ fn a😀b() -> i32 { 1; }
    ·     ^^
  2 │ 
  [128]
