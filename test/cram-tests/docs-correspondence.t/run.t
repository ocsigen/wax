Compile check for the self-contained examples on the correspondence pages
(types.md, instructions.md, module_fields.md). Like the language guide, the
check is opt-in because many correspondence snippets are fragments (single
expressions, partial forms) that do not stand alone: fence a block ```wax,check
(instead of plain ```wax) whenever it is self-contained, and it will be
type-checked and converted to WAT. Mark every standalone block this way. To
update after editing the docs, re-run `dune runtest` and `dune promote`.

Extract each ```wax,check block, prefixed by its page:

  $ for s in types instructions module_fields; do awk -v s=$s '/^```wax,check$/ {f=1; n++; out=sprintf("%s%02d.wax", s, n); next} /^```$/ {f=0; next} f {print > out}' ../../../docs/src/correspondence/$s.md; done

Confirm the count (bump and promote when you mark or unmark a block):

  $ ls *.wax | wc -l | tr -d ' '
  33

Each marked block must compile (a failing block prints its name and first
error; success prints nothing):

  $ for f in *.wax; do wax -X custom-descriptors -v -f wat "$f" >/dev/null 2>&1 || echo "FAILED: $f -- $(wax -X custom-descriptors -v -f wat "$f" 2>&1 | grep -m1 -i error)"; done
