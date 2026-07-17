A WAT block label that `sanitize_identifier` rejects (here `$a--b`, whose double
dash cannot become a Wax identifier) has no Wax name, so it renders under the
generated fallback `'l`. `label_targeted` must still count such a block as a
branch target when a symbolic `br $a--b` names it -- otherwise the fallback name
is never reserved, an inner anonymous targeted block claims `'l` too, and the
outer branch silently retargets to the inner block.

  $ cat > f.wat <<'WAT'
  > (module (func (block $a--b (block (br 0) (br $a--b)))))
  > WAT

  $ wax -i wat -f wax f.wat
  fn f() {
      'l: do {
          'l_2: do {
              br 'l_2;
              br 'l;
          }
      }
  }

The round trip keeps each branch on its original target (the inner `br 0` on the
inner block, the outer `br $a--b` on the outer block):

  $ wax -i wat -f wax f.wat | wax -i wax -f wat
  (func $f (block $l (block $l_2 (br $l_2) (br $l))))
