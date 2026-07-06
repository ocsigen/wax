The branch-hinting proposal is preserved by default (no feature flag). A Wax
[#[likely]] / [#[unlikely]] on an [if]/[br_if] becomes a
[metadata.code.branch_hint] entry; on the way back it prints as the same Wax
attribute or the WAT [(@metadata.code.branch_hint …)] annotation.

Wax hints print as the WAT annotation preceding the hinted instruction:

  $ wax -i wax -f wat hints.wax
  (func $f (param $x i32) (result i32)
    (@metadata.code.branch_hint "\01")
    (if (result i32) (local.get $x) (then (i32.const 1)) (else (i32.const 2)))
  )
  
  (func $g (param $x i32)
    (loop $l (@metadata.code.branch_hint "\00") (br_if $l (local.get $x)))
  )

Wax hints survive a Wax round-trip:

  $ wax -i wax -f wax hints.wax
  fn f(x: i32) -> i32 {
      #[likely]
      if x => i32 {
          1;
      } else {
          2;
      }
  }
  
  fn g(x: i32) {
      'l: loop {
          #[unlikely]
          br_if 'l x;
      }
  }

A WAT annotation decompiles to the Wax attribute:

  $ wax -i wat -f wax hints.wat
  type t = { };
  fn f(x: i32) -> i32 {
      #[likely]
      if x {
          1;
      } else {
          2;
      }
  }
  fn f_2(x: i32) {
      'l: do {
          #[unlikely]
          br_if 'l x;
      }
  }
  // A hint on a br_on_* branch (all conditional branches are supported).
  fn f_3(x: &?any) -> &t 'l: {
      #[likely]
      br_on_cast 'l &t x;
      unreachable;
  }

The WAT annotation round-trips through the binary unchanged:

  $ wax -i wat -f wat hints.wat
  (type $t (struct))
  (func (param i32) (result i32)
    local.get 0
    (@metadata.code.branch_hint "\01")
    if (result i32) i32.const 1 else i32.const 2 end
  )
  (func (param i32)
    block local.get 0 (@metadata.code.branch_hint "\00") br_if 0 end
  )
  ;; A hint on a br_on_* branch (all conditional branches are supported).
  (func (param anyref) (result (ref $t))
    local.get 0
    (@metadata.code.branch_hint "\01") br_on_cast 0 anyref (ref $t)
    unreachable
  )
