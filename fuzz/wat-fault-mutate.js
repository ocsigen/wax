// wat-fault-mutate.js — plant exactly ONE fault in a WAT module: retarget a
// single USE-SITE identifier at a fresh, unbound name, leaving every
// definition (and every other use) intact. The sibling of wat-numid-mutate.js
// (same string/comment-aware scan); the paired driver is fault-locality.sh.
//
//   node wat-fault-mutate.js [file.wat] --count    -> prints the number of
//                                                     retargetable uses
//   FAULT=k node wat-fault-mutate.js [file.wat]    -> retargets the k-th
//                                                     (0-based) use; prints the
//                                                     mutant on stdout and the
//                                                     fault's 1-based line
//                                                     number on stderr
//
// A "use" is any $identifier occurrence that is not a BINDER — not the name
// being bound by a definition ((type/func/global/table/memory/tag/elem/data/
// local/param $x ...), a folded or unfolded block/loop/if/try label binder) and
// not a label REPEAT (the optional $l after end/else/catch/delegate, which must
// echo the binder). Retargeting one use at an unbound name is a single, located
// fault: the locality invariant (fault-locality.sh) is that wax reports exactly
// the unbound-reference error AT THAT LINE and nothing else — no cascade from a
// shifted index space, no wrong-entity resolution at other sites.

const fs = require("fs");
const src = fs.readFileSync(process.argv[2] && process.argv[2] !== "--count" ? process.argv[2] : 0, "utf8");
const countMode = process.argv.includes("--count");
const FAULT = parseInt(process.env.FAULT || "-1", 10);
const FRESH = "$__fuzz_unbound__";

// Offsets of every $identifier that must NOT be retargeted: a BINDER (or
// label repeat), or an occurrence too ambiguous to classify.
const binders = new Set();
{
  // Field/local binders: ($kw $name ...). `rec`, `export`, `import`, `start`
  // are absent on purpose: the $name after (func inside an import IS a binder
  // and is caught by its own (func; (start $f) / (export "x" (func $f)) are
  // uses. A declaration CONTINUES after the name, while the same-keyword
  // reference forms — the typeuse `(type $t)`, an export target `(func $f)` —
  // close immediately, so a `)` right after the name (a lookahead: consuming
  // it would swallow the `(` of an adjacent form and skip its keyword) marks
  // the reference form. `(type $t)` is then always a use (a name-only type
  // declaration cannot exist); the other name-only forms are ambiguous — the
  // export/import descriptors read the same as an empty declaration
  // (`(func $f)` declares an empty function) — so they are left alone
  // entirely: neither faulted nor counted.
  const defRe = /\((module|type|func|global|table|memory|tag|elem|data|local|param|field)\s+(\$[^\s()]+)(?=\s*(\)?))/g;
  let m;
  while ((m = defRe.exec(src)) !== null) {
    const off = m.index + m[0].length - m[2].length;
    if (m[3] === ")") {
      if (m[1] !== "type") binders.add(off); // ambiguous name-only form
    } else binders.add(off); // a declaration: the binder
  }
  // Label binders and repeats, folded or unfolded: the $l right after the
  // keyword. `end $l` / `else $l` / `catch* $l` / `delegate $l` echo a binder;
  // retargeting them is a same-line mismatch, not the index-space fault this
  // mutator isolates, so they are excluded too.
  const labRe = /(?:\(|^|\s)(block|loop|if|then|else|end|try_table|try|catch_all|catch|delegate)\s+(\$[^\s()]+)/gm;
  while ((m = labRe.exec(src)) !== null) binders.add(m.index + m[0].length - m[2].length);
}

// The string/comment-aware identifier scan (as in wast-rewrite.js).
function scanWat(text, onId, onOther) {
  const isDelim = (c) => c === undefined || /[\s()";]/.test(c);
  let i = 0;
  const n = text.length;
  let run = 0;
  const flush = (end) => { if (end > run) onOther(text.slice(run, end)); };
  while (i < n) {
    const c = text[i];
    if (c === '"') { let j = i + 1; while (j < n && text[j] !== '"') { if (text[j] === "\\") j++; j++; } i = j + 1; continue; }
    if (c === ";" && text[i + 1] === ";") { while (i < n && text[i] !== "\n") i++; continue; }
    if (c === "(" && text[i + 1] === ";") { let d = 1; i += 2; while (i < n && d > 0) { if (text[i] === "(" && text[i + 1] === ";") { d += 1; i += 2; } else if (text[i] === ";" && text[i + 1] === ")") { d -= 1; i += 2; } else i++; } continue; }
    if (c === "$") { flush(i); let j = i + 1; while (j < n && !isDelim(text[j])) j++; onId(i, text.slice(i, j)); run = j; i = j; continue; }
    i++;
  }
  flush(n);
}

// Collect use occurrences (source order).
const uses = [];
scanWat(src, (start, id) => { if (!binders.has(start)) uses.push({ start, len: id.length }); }, () => {});

if (countMode) {
  process.stdout.write(String(uses.length) + "\n");
} else if (FAULT >= 0 && FAULT < uses.length) {
  const u = uses[FAULT];
  const line = src.slice(0, u.start).split("\n").length;
  process.stdout.write(src.slice(0, u.start) + FRESH + src.slice(u.start + u.len));
  process.stderr.write(String(line) + "\n");
} else {
  process.stdout.write(src); // out of range: unchanged
}
