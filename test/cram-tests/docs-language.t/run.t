Opt-in compile check for docs/src/language.md. Unlike examples.md and
introduction.md — whose every ```wax block is checked — the language guide is
mostly illustrative fragments (holes, ellipses, build-up sequences) that do not
compile standalone. So a block is checked only when it opts in by fencing it
```wax,check instead of ```wax; such a block must be self-contained and must
type-check and convert to WAT. To update after editing the docs, re-run
`dune runtest` and `dune promote`.

Extract each ```wax,check block:

  $ awk '/^```wax,check$/ {f=1; n++; out=sprintf("blk%02d.wax", n); next} /^```$/ {f=0; next} f {print > out}' ../../../docs/src/language.md

Confirm the count (bump and promote when you mark or unmark a block):

  $ ls blk*.wax | wc -l | tr -d ' '
  9

Each marked block must compile (a failing block prints its name and first
error; success prints nothing):

  $ for f in blk*.wax; do wax -X custom-descriptors -v -f wat "$f" >/dev/null 2>&1 || echo "FAILED: $f -- $(wax -X custom-descriptors -v -f wat "$f" 2>&1 | grep -m1 -i error)"; done
