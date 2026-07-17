A tag with no payload is written with an empty signature, `tag stop();`. It
type-checks, round-trips, and lowers to WAT and to the binary format.

  $ cat > stop.wax <<'EOF'
  > tag stop();
  > fn m() { throw stop(); }
  > fn f() {
  >     try { m(); } catch { stop => { nop; } }
  > }
  > EOF

  $ wax -f wax --validate stop.wax
  tag stop();
  fn m() {
      throw stop();
  }
  fn f() {
      try {
          m();
      } catch {
          stop => {
              nop;
          }
      }
  }

  $ wax -f wat --validate stop.wax
  (tag $stop)
  (func $m (throw $stop))
  (func $f
    (block $join
      (block $catch (try_table (catch $stop $catch) (call $m)) (br $join))
      (nop))
  )

  $ wax -f wasm stop.wax -o stop.wasm && wc -c < stop.wasm | tr -d ' '
  96

The parentheses are required: a bare `tag NAME;` or `fn NAME { … }` (no
parameter list and no type reference) is a syntax error, not an empty signature.

  $ printf 'tag stop;\n' | wax -i wax -f wat
  Error: A parameter list is required.
   ──➤  -:1:1
  1 │ tag stop;
    · ^^^^^^^^
  2 │ 
  Help: insert '()'
  [128]


  $ printf 'fn f { nop; }\n' | wax -i wax -f wat
  Error: A parameter list is required.
   ──➤  -:1:1
  1 │ fn f { nop; }
    · ^^^^
  2 │ 
  Help: insert '()'
  [128]

