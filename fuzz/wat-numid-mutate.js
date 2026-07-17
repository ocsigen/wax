// wat-numid-mutate.js — flip ONE named type reference in a WAT module to its
// numeric type index, a semantics-preserving rewrite. Reads WAT on stdin or a
// file arg; writes the mutant to stdout, or (with --count) the number of
// flippable references to stdout.
//
//   node wat-numid-mutate.js [file.wat] --count   -> prints occurrence count
//   FLIP=k node wat-numid-mutate.js [file.wat]     -> flips the k-th (0-based)
//
// Only unambiguous type-reference contexts are rewritten — (type $x), (ref $x),
// (ref null $x) — leaving every other $name (funcs, globals, locals, labels,
// struct.new, ...) alone. Flipping a SINGLE correct name->index reference keeps
// the module identical but makes it reference one type numerically while its
// siblings stay symbolic. from_wasm must still decompile the mutant to the SAME
// Wax as the original; that metamorphic equality is the oracle (num-id-fuzz.sh).
// A difference means from_wasm treated the symbolic and numeric forms of the
// SAME type differently — e.g. minted a spurious implicit type because
// heaptype_eq did not equate `Num N` with the `$name` it resolves to (the
// mixed-reference case a whole-module flip would paper over).

const fs = require("fs");
const src = fs.readFileSync(process.argv[2] && process.argv[2] !== "--count" ? process.argv[2] : 0, "utf8");
const countMode = process.argv.includes("--count");
const FLIP = parseInt(process.env.FLIP || "-1", 10);

// Build name -> type index from (type ...) DECLARATIONS in source order. A
// declaration is `(type [$name] (func|struct|array|sub|cont ...` — a composite
// type follows; a reference `(type $x)` has `)` after the name and is skipped
// here. A (rec ...) group just holds more declarations and consumes no index.
const nameToIndex = Object.create(null);
{
  let idx = 0, m;
  const declRe = /\(\s*type\b\s*(\$[^\s()]+)?\s*\(/g;
  while ((m = declRe.exec(src)) !== null) {
    if (m[1]) nameToIndex[m[1]] = idx;
    idx++;
  }
}

// Collect flippable reference occurrences (source order): (type $x) [ref form,
// closed by `)`], (ref $x), (ref null $x), where $x names a declared type.
const refRe = /\(\s*type\s+(\$[^\s()]+)\s*\)|\(\s*ref\s+(null\s+)?(\$[^\s()]+)\s*\)/g;
const occ = [];
{
  let m;
  while ((m = refRe.exec(src)) !== null) {
    if (m[1] !== undefined) {
      if (!(m[1] in nameToIndex)) continue;
      occ.push({ start: m.index, len: m[0].length, repl: "(type " + nameToIndex[m[1]] + ")" });
    } else {
      if (!(m[3] in nameToIndex)) continue;
      occ.push({ start: m.index, len: m[0].length, repl: "(ref " + (m[2] ? "null " : "") + nameToIndex[m[3]] + ")" });
    }
  }
}

if (countMode) {
  process.stdout.write(String(occ.length) + "\n");
} else if (FLIP >= 0 && FLIP < occ.length) {
  const o = occ[FLIP];
  process.stdout.write(src.slice(0, o.start) + o.repl + src.slice(o.start + o.len));
} else {
  process.stdout.write(src); // out of range: unchanged
}
