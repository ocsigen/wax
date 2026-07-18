ref.get_desc reads the descriptor of its operand. Its result is exact exactly
when the operand is (the shared exact_1 in the spec): an exact or bottom operand
gives an exact descriptor, an inexact operand an inexact one. from_wasm must
preserve that on the round-trip — it does not cast a concrete operand (which
already carries a descriptor-bearing type, so casting would only strip its
exactness), and pins a bottom operand (a null / hole) to the *exact* descriptor
type.

  $ wax -X custom-descriptors -i wat -f wax rgd.wat
  #![feature = "custom-descriptors"]
  rec {
      type a = descriptor b { };
      type b = describes a { };
  }
  // exact operand -> exact descriptor
  #[export]
  fn exact(x: &!a) -> &!b {
      x.descriptor;
  }
  // a bottom (null) operand fits the exact operand type -> exact descriptor
  #[export = "null"]
  fn f() -> &!b {
      (null as &?!a).descriptor;
  }
  // inexact operand -> inexact descriptor
  #[export]
  fn inexact(x: &a) -> &b {
      x.descriptor;
  }

The decompilation round-trips back to a valid module.

  $ wax -X custom-descriptors --validate -i wat -f wasm rgd.wat -o /dev/null

ref.get_desc to a strict subtype's exact type is invalid: an operand of exactly
$c (a subtype of $a, with its own descriptor) does not yield $a's exact
descriptor, so the result must not be typed exact. The diagnostic names the
descriptor ($b), not the described type.

  $ wax check -X custom-descriptors -f wat bad.wat
  Error:
    Type mismatch: this produces a value of type '(ref $b)', but type
    '(ref (exact $b))' is expected.
   ──➤  bad.wat:8:6
  6 │     (type $d (sub $b (describes $c) (struct))))
  7 │   (func (param (ref (exact $c))) (result (ref (exact $b)))
  8 │     (ref.get_desc $a (local.get 0))))
    ·      ^^^^^^^^^^^^^^^
  9 │ 
  [128]
