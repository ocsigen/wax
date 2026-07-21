// wax-fault-mutate.js — plant exactly ONE fault in a Wax program: retarget a
// single USE-SITE identifier at a fresh, unbound name. The .wax sibling of
// wat-fault-mutate.js; the paired driver is fault-locality.sh.
//
//   node wax-fault-mutate.js [file.wax] --count    -> number of retargetable uses
//   FAULT=k node wax-fault-mutate.js [file.wax]    -> retargets the k-th
//                                                     (0-based) use; mutant on
//                                                     stdout, fault's 1-based
//                                                     line number on stderr
//
// Wax identifiers are bare words (no $ sigil), so classifying an arbitrary
// occurrence as binder vs use needs scope analysis. Instead only two
// unambiguous, abundant use classes are faulted, chosen so the locality
// invariant provably holds today:
//
//   * a CALLEE — `name(` at a fresh token start (not `.name(` = method, not
//     `::name(` = intrinsic path, not `fn name(` = the definition) and not a
//     keyword: resolves through the value namespace, one unbound-variable
//     error at the call;
//   * a LABEL USE — `'name` right after a branch keyword (`br`, `br_if`,
//     `br_table`, and the value-carrying `br_on_*` family, whose recovery
//     passes the fall-through values through unchanged since the
//     branch-recovery fixes): one unbound-label error at the branch. (A
//     binder is the `'name:` prefix form, never after a branch keyword.)
//   * a CONSTRUCTION NAME — the `T` of a struct/array literal (`{T| ...}` /
//     `[T| ...]`): one unbound-type error at the literal (silently accepted
//     before the lookup_*_type fix).
//
// The explicit-type form of a signature (`fn f: T (…)`) stays excluded via
// the `:` check below — not because it cascades (a failed signature is now a
// poison entry whose callers stay quiet), but because its single error lands
// on the DEFINITION's line, which for a multi-line declaration differs from
// the reference's line; the plain locality assertion keys on the fault line.
// Hole-style modules are faultable again: a failed producer now poisons the
// pending stack, so hole consumers absorb it silently.

const fs = require("fs");
const src = fs.readFileSync(process.argv[2] && process.argv[2] !== "--count" ? process.argv[2] : 0, "utf8");
const countMode = process.argv.includes("--count");
const FAULT = parseInt(process.env.FAULT || "-1", 10);
const FRESH = "__fuzz_unbound__";

const KEYWORDS = new Set([
  "fn", "if", "else", "while", "do", "loop", "match", "dispatch", "try",
  "catch", "return", "become", "throw", "throw_ref", "select", "as", "is",
  "let", "const", "type", "tag", "import", "export", "memory", "table",
  "elem", "data", "module", "null", "unreachable", "nop", "new",
  "br", "br_if", "br_table", "br_on_null", "br_on_non_null", "br_on_cast",
  "br_on_cast_fail", "br_on_cast_desc_eq", "br_on_cast_desc_eq_fail",
  "cont_new", "cont_bind", "suspend", "resume", "resume_throw",
  "resume_throw_ref", "switch", "on", "descriptor",
]);
const BRANCH = /(?:^|[^A-Za-z0-9_])(br|br_if|br_table|br_on_null|br_on_non_null|br_on_cast(?:_fail)?(?:_desc_eq(?:_fail)?)?)\s+('?[A-Za-z_][A-Za-z0-9_]*)/g;

// Walk the source outside strings and comments, collecting use occurrences.
// Wax comments are // and /* */ (non-nested is fine for corpus code); strings
// are "..." with escapes. A `'` introduces a label (or char literal — both
// skipped by the callee scan; labels are matched by the branch regex below).
const uses = [];
{
  let i = 0;
  const n = src.length;
  const isWord = (c) => /[A-Za-z0-9_]/.test(c || "");
  while (i < n) {
    const c = src[i];
    if (c === '"') { i++; while (i < n && src[i] !== '"') { if (src[i] === "\\") i++; i++; } i++; continue; }
    if (c === "/" && src[i + 1] === "/") { while (i < n && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") { i += 2; while (i < n && !(src[i] === "*" && src[i + 1] === "/")) i++; i += 2; continue; }
    if (/[A-Za-z_]/.test(c) && !isWord(src[i - 1])) {
      let j = i;
      while (j < n && isWord(src[j])) j++;
      const word = src.slice(i, j);
      // Callee position: identifier directly followed by `(`, at a fresh
      // token start (the char before is not `.`/`:`/`'`/`&`), not a keyword,
      // and not preceded by the `fn` keyword (a definition).
      let k = j;
      while (k < n && (src[k] === " " || src[k] === "\t")) k++;
      // The previous non-space character: excludes `.name(` (method),
      // `::name(` and `x: name (` (a type annotation, e.g. the import /
      // explicit-type form `fn f: T (…)`), `&name(`, `'name(`, and `&?name (`
      // (a nullable ref type in e.g. `br_on_cast 'l &?T (…)`, whose `?` is the
      // only context an identifier follows a `?`) — a type, not a callee.
      let e = i - 1;
      while (e >= 0 && /[ \t\n]/.test(src[e])) e--;
      const prev = e >= 0 ? src[e] : "";
      const prevWord = (() => {
        let ee = e;
        let s = ee;
        while (s >= 0 && isWord(src[s])) s--;
        return src.slice(s + 1, ee + 1);
      })();
      if (
        src[k] === "(" && !KEYWORDS.has(word) &&
        prev !== "." && prev !== ":" && prev !== "'" && prev !== "&" &&
        prev !== "?" && prevWord !== "fn"
      )
        // A call: the callee's signature — hence its arity — is unknown once
        // unbound, so recovery cannot keep the stack aligned for the hole
        // operands that follow (see fault-locality.sh's [call] handling).
        uses.push({ start: i, len: word.length, repl: FRESH, kind: "call" });
      // Construction name: `{T| ...}` / `[T| ...]`.
      else if ((prev === "{" || prev === "[") && src[k] === "|")
        uses.push({ start: i, len: word.length, repl: FRESH, kind: "type" });
      i = j;
      continue;
    }
    i++;
  }
}
// Label uses after a branch keyword (collected separately; positions may
// interleave with callee positions, so sort by offset for stable indexing).
{
  let m;
  while ((m = BRANCH.exec(src)) !== null) {
    const tok = m[2];
    if (!tok.startsWith("'")) continue; // e.g. `br_table` with numeric depths
    const start = m.index + m[0].length - tok.length + 1; // skip the quote
    uses.push({ start, len: tok.length - 1, repl: FRESH, kind: "label" });
  }
}
uses.sort((a, b) => a.start - b.start);

if (countMode) {
  process.stdout.write(String(uses.length) + "\n");
} else if (FAULT >= 0 && FAULT < uses.length) {
  const u = uses[FAULT];
  const line = src.slice(0, u.start).split("\n").length;
  process.stdout.write(src.slice(0, u.start) + u.repl + src.slice(u.start + u.len));
  // Emit "<line> <kind>": the fault line for the locality check, and the fault
  // kind so the oracle can skip the (unachievable) locality check for an
  // unknown-arity fault.
  process.stderr.write(String(line) + " " + u.kind + "\n");
} else {
  process.stdout.write(src); // out of range: unchanged
}
