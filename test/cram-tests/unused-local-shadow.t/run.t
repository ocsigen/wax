The `unused-local` lint tracks reads by the binding's source offset, not its
name, so a local that is shadowed before it is ever read is still reported. Here
the first `x` is dead: the later `let x` shadows it and only that inner binding
is read. (Keyed by name, the inner read would have masked the outer one.)

  $ wax check -W unused-local=warning shadow.wax
  Warning [unused-local]: The local variable 'x' is never used.
   ──➤  shadow.wax:2:9
  1 │ fn f() -> i64 {
  2 │     let x: i64 = 7;
    ·         ^
  3 │     let x: i64 = 8;
  4 │     x;
