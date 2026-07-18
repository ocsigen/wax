Converting Wasm back to Wax reconstructs `..` when a struct subtype's leading
fields exactly match (name and type) its supertype's full field list. A renamed
or covariantly-refined inherited field is not a verbatim copy, so it stays
explicit.

  $ wax -i wat -f wax - <<'WAT'
  > (module
  >   (type $base (sub (struct (field $a i32))))
  >   (type $ext (sub $base (struct (field $a i32) (field $b i64))))
  >   (rec
  >     (type $c (sub (struct (field $x i32))))
  >     (type $d (sub $c (struct (field $x i32) (field $y i32)))))
  >   (type $e (sub (struct (field $x i32))))
  >   (type $chain (sub $d (struct (field $x i32) (field $y i32) (field $z i32))))
  >   (type $renamed (sub $base (struct (field $other i32) (field $z i32))))
  >   (type $refined_p (sub (struct (field $f (ref null $base)))))
  >   (type $refined (sub $refined_p (struct (field $f (ref $base)) (field $w i32)))))
  > WAT
  type base = open { a: i32 };
  type ext: base = open { .., b: i64 };
  rec {
      type c = open { x: i32 };
      type d: c = open { .., y: i32 };
  }
  type e = open { x: i32 };
  type chain: d = open { .., z: i32 };
  type renamed: base = open { other: i32, z: i32 };
  type refined_p = open { f: &?base };
  type refined: refined_p = open { f: &base, w: i32 };

The reconstructed `..` round-trips: recompiling the Wax reproduces the module.

  $ wax -i wat -f wax - <<'WAT' -o m.wax
  > (module
  >   (type $base (sub (struct (field $a i32))))
  >   (type $ext (sub $base (struct (field $a i32) (field $b i64)))))
  > WAT
  $ wax -i wax -f wasm --validate m.wax -o /dev/null && echo ok
  ok
