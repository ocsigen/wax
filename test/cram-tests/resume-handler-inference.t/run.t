A block used as a `resume` handler keeps its result-type annotation (the
delivered continuation type is load-bearing) and converts without a spurious
stack-switching type mismatch while the simplify pass is inferring block
results:

  $ wax cont.wat -f wax
  tag e2();
  type f1 = fn();
  type k1 = cont f1;
  fn f1() {}
  #[export]
  fn u3() {
      _ =
          'h: do &k1 {
              k1::new(f1).resume() on [e2 -> 'h];
              unreachable;
          };
  }

It round-trips, reproducing the original handler block:

  $ wax cont.wat -f wax | wax -i wax -f wat
  (tag $e2)
  (type $f1 (func))
  (type $k1 (cont $f1))
  (func $f1)
  (func $u3 (export "u3")
    (drop
      (block $h (result (ref $k1))
        (resume $k1 (on $e2 $h) (cont.new $k1 (ref.func $f1)))
        (unreachable)))
  )
  (elem declare func $f1)
