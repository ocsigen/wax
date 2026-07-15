A tail call (`become`) whose target's typing fails — here the "callee" is a
struct value, not a function — must report the underlying error, not crash.
(type_branch's TailCall case assumed call_instruction returns a Call node and hit
`assert false` otherwise; a failed lookup yields an Unreachable/Error node
instead. Found by fuzz/mutate-wax.sh.)

  $ cat > m.wax <<'WAX'
  > type S = { x: i32 };
  > fn f() { become {S| x: 0}(); }
  > WAX
  $ wax check m.wax
  Error: Expected function type.
   ──➤  m.wax:2:18
  1 │ type S = { x: i32 };
  2 │ fn f() { become {S| x: 0}(); }
    ·                  ^
  3 │ 
  [128]
