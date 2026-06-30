`-literal` folds into a single signed constant, but only when the negation is
representable. A magnitude that is a valid *unsigned* const yet overflows the
signed minimum when negated (here u64 max as i64) must not be folded into an
out-of-range `i64.const -…` — that crashed the encoder. It falls through to the
general `0 - x` lowering instead (the positive literal is the valid unsigned bit
pattern -1, so the result is 1). Regression: found by the AST-mutation fuzzer.

  $ cat > over.wax <<'EOF'
  > fn f() -> i64 {
  >     -18446744073709551615;
  > }
  > EOF
  $ wax -i wax -f wat over.wax --validate
  (func $f (result i64)
    (i64.sub (i64.const 0) (i64.const 18446744073709551615))
  )

In-range negative literals still fold to a single constant (including the signed
minimum, -2^63):

  $ cat > ok.wax <<'EOF'
  > fn g() -> i64 {
  >     -5;
  > }
  > fn h() -> i64 {
  >     -9223372036854775808;
  > }
  > EOF
  $ wax -i wax -f wat ok.wax --validate | grep const
  (func $g (result i64) (i64.const -5))
  (func $h (result i64) (i64.const -9223372036854775808))
