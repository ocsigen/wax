A br_on_cast targeting a label of arity > 1 carries all the label's values, so
its operand is a multi-value sequence (the cast value is the last/top). Lowering
it must read the reference type from that last value, not from the whole
multi-value expression (which would assert in to_wasm). Regression: found by
smith.

  $ cat > t.wax <<'EOF'
  > fn f(a: &?any, b: &?any) -> &?any {
  >     'l: do () -> (&?any, &?any) {
  >         br_on_cast 'l &?any (a, b);
  >         _ = _;
  >         _ = _;
  >         unreachable;
  >     }
  >     _ = _;
  > }
  > EOF
  $ wax -i wax -f wasm t.wax -o /dev/null --validate
