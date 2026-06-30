`_ = e` drops one value, so `e` must produce exactly one. Dropping a void
expression (a call to a function with no result) used to be accepted, emitting a
`drop` with nothing on the stack — invalid wasm. It is now rejected. Regression:
found by the AST-mutation fuzzer (a void call grafted into a `_ = …` position).

  $ cat > drop.wax <<'EOF'
  > fn g() {}
  > fn f() {
  >     _ = g();
  > }
  > EOF
  $ wax -i wax -f wasm drop.wax -o /dev/null
  Error: An expression is expected here. This instruction returns 0 values.
   ──➤  drop.wax:3:9
  1 │ fn g() {}
  2 │ fn f() {
  3 │     _ = g();
    ·         ^^^
  4 │ }
  5 │ 
  [128]

Dropping a value-producing call, and calling a void function as a statement, are
both still fine:

  $ cat > ok.wax <<'EOF'
  > fn g() -> i32 { 5; }
  > fn h() {}
  > fn f() {
  >     _ = g();
  >     h();
  > }
  > EOF
  $ wax -i wax -f wasm ok.wax -o /dev/null --validate
