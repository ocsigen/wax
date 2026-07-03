Every ```wax code block in docs/src/introduction.md must still compile with the
current toolchain, so the front-page examples do not rot. To update after
editing the docs, re-run `dune runtest` and `dune promote`.

Extract each ```wax block into its own file:

  $ awk '/^```wax$/ {f=1; n++; out=sprintf("blk%02d.wax", n); next} /^```$/ {f=0; next} f {print > out}' ../../../docs/src/introduction.md

Confirm the expected number of blocks was extracted (bump this and promote when
you add or remove one):

  $ ls blk*.wax | wc -l | tr -d ' '
  2

Each block must type-check and convert to WAT (a failing block prints its name
and first error; success prints nothing):

  $ for f in blk*.wax; do wax -X custom-descriptors -v -f wat "$f" >/dev/null 2>&1 || echo "FAILED: $f -- $(wax -X custom-descriptors -v -f wat "$f" 2>&1 | grep -m1 -i error)"; done
