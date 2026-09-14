"Expected function type" is reported at the CALLEE's own location, not at the
type reference the callee's declared type points at. Reported there, every call
of one such local landed on the SAME spot — indistinguishable duplicate
diagnostics when there are two of them, and never pointing at the call that is
actually wrong (a mutate-wax DIAG_DUP finding).

  $ cat > c.wax <<'WAX'
  > type f = fn();
  > type k = cont f;
  > fn f1() {}
  > #[export]
  > fn g() {
  >     let k_ref = k::new(f1);
  >     k_ref();
  >     k_ref();
  > }
  > WAX
  $ wax check --error-format short c.wax
  c.wax:7:5: error: Expected function type.
  c.wax:8:5: error: Expected function type.
  [128]
