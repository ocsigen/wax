Assembly check for the complete ```wat examples across the docs. WAT blocks are
often partial (they elide a type or a body, or trail off with an ellipsis), so
the check is opt-in: fence a block ```wat,check (instead of plain ```wat)
whenever it is a complete module, and it will be assembled to a valid Wasm
binary. Mark every standalone block this way. To update after editing the docs,
re-run `dune runtest` and `dune promote`.

Extract each ```wat,check block from every doc page (prefixed by its page):

  $ for f in ../../../docs/src/*.md ../../../docs/src/correspondence/*.md; do awk -v s="$(basename "$f" .md)" '/^```wat,check$/ {c=1; n++; out=sprintf("%s%02d.wat", s, n); next} /^```$/ {c=0; next} c {print > out}' "$f"; done

Confirm the count (bump and promote when you mark or unmark a block):

  $ ls *.wat | wc -l | tr -d ' '
  14

Each block must assemble to a valid Wasm binary (a failing block prints its name
and first error; success prints nothing):

  $ for f in *.wat; do wax -i wat -X custom-descriptors -v -f wasm -o "$f.wasm" "$f" >/dev/null 2>&1 || echo "FAILED: $f -- $(wax -i wat -X custom-descriptors -v -f wasm -o "$f.wasm" "$f" 2>&1 | grep -m1 -i error)"; done
