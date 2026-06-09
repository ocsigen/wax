Every ```wax code block in docs/src/examples.md must still compile with the
current toolchain. This keeps the documentation from silently rotting when the
Wax syntax or type system changes. To update after editing the docs, re-run
`dune runtest` and `dune promote`.

Extract each ```wax block into its own file:

  $ awk '/^```wax$/ {f=1; n++; out=sprintf("blk%02d.wax", n); next} /^```$/ {f=0; next} f {print > out}' ../../../docs/src/examples.md

Confirm the expected number of examples was extracted (bump this and promote
when you add or remove an example):

  $ ls blk*.wax | wc -l
  11

Each example must type-check and convert to WAT. A failing block prints its
name and first error; success prints nothing:

  $ for f in blk*.wax; do wax -v -f wat "$f" >/dev/null 2>&1 || echo "FAILED: $f -- $(wax -v -f wat "$f" 2>&1 | grep -m1 -i error)"; done
