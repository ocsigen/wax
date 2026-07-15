Compile check for the self-contained ```wax examples in docs/src/language.md.
Unlike examples.md and introduction.md, whose every ```wax block is checked, the
language guide also has many illustrative fragments (holes, ellipses, build-up
sequences, bare syntax snippets) that do not compile on their own, so the check
cannot blindly cover every block. It is therefore opt-in: fence a block
```wax,check (instead of plain ```wax) whenever it is self-contained, and it will
be type-checked and converted to WAT. Mark every standalone block this way. To
update after editing the docs, re-run `dune runtest` and `dune promote`.

Extract each ```wax,check block:

  $ awk '/^```wax,check$/ {f=1; n++; out=sprintf("blk%02d.wax", n); next} /^```$/ {f=0; next} f {print > out}' ../../../docs/src/language.md

Confirm the count (bump and promote when you mark or unmark a block):

  $ ls blk*.wax | wc -l | tr -d ' '
  47

Each marked block must compile (a failing block prints its name and first
error; success prints nothing):

  $ for f in blk*.wax; do wax -X custom-descriptors -v -f wat "$f" >/dev/null 2>&1 || echo "FAILED: $f -- $(wax -X custom-descriptors -v -f wat "$f" 2>&1 | grep -m1 -i error)"; done
