The `unused-label` lint tracks label usage per binding (by the declaration's
source offset), not by name. So an inner label that shadows an outer one of the
same name, and is the only one branched to, does not mask the outer label: the
unused outer `'l` is still reported. This matches the Wasm validator, which
tracks usage per control frame.

  $ wax check -W unused-label=warning shadow.wax
  Warning [unused-label]: The label 'l' is never used.
   ──➤  shadow.wax:3:5
  1 │ #[export = "f"]
  2 │ fn f() {
  3 │     'l: do {
    ·     ^^
  4 │         'l: do {
  5 │             br 'l;
