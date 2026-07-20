// wast-extract.js — extract every top-level *text* module of a .wast script
// into its own .wat file. The sibling of wast-rewrite.js (same s-expression
// walker), but a harvester instead of a rewriter: modules nested inside
// assert_invalid / assert_malformed stay behind (they are not top-level
// groups), as do the (module binary "...") / (module quote "...") forms and
// module-definition/instance forms, so what comes out is exactly the scripts'
// known-valid text modules — corpus food for the cross-proposal seeds
// (stack switching, custom descriptors) that wasm-smith cannot generate.
//
//   node wast-extract.js <file.wast> <outdir> <prefix>
//
// Writes <outdir>/<prefix>-<n>.wat per module and prints the count to stdout.
// With FEATURE set (e.g. FEATURE=custom-descriptors), injects a
// (@feature "<name>") module annotation right after the module head, so the
// module self-declares the gated proposal and validates under a plain
// `wax check` with no -X flag (the oracle passes none).

const fs = require("fs");
const path = require("path");

const file = process.argv[2];
const outdir = process.argv[3];
const prefix = process.argv[4] || "mod";
const FEATURE = process.env.FEATURE;
const src = fs.readFileSync(file, "utf8");

let count = 0;

function emitModule(group) {
  // Only a plain text module: `(module` optionally `$name`, then a subform.
  // Any keyword there (binary / quote / definition / instance) is not ours.
  const m = group.match(/^\(\s*module\b\s*(\$[^\s()]+)?\s*([a-z]*)/);
  if (!m || m[2] !== "") return;
  let text = group;
  if (FEATURE)
    text = text.replace(/^\(\s*module\b(\s*\$[^\s()]+)?/,
      (h) => h + ' (@feature "' + FEATURE + '")');
  fs.writeFileSync(path.join(outdir, prefix + "-" + count + ".wat"), text + "\n");
  count++;
}

// Walk the script; only ( ... ) groups need parsing (to find their extent,
// respecting strings and comments). Same walker as wast-rewrite.js.
let i = 0;
const n = src.length;
while (i < n) {
  if (src[i] === "(" && src[i + 1] === ";") { // block comment (nestable)
    let d = 1, j = i + 2;
    while (j < n && d > 0) {
      if (src[j] === "(" && src[j + 1] === ";") { d++; j += 2; }
      else if (src[j] === ";" && src[j + 1] === ")") { d--; j += 2; }
      else j++;
    }
    i = j; continue;
  }
  if (src[i] === ";" && src[i + 1] === ";") { while (i < n && src[i] !== "\n") i++; continue; }
  if (src[i] === "(") {
    let d = 0, j = i;
    while (j < n) {
      const c = src[j];
      if (c === '"') { j++; while (j < n && src[j] !== '"') { if (src[j] === "\\") j++; j++; } j++; continue; }
      if (c === ";" && src[j + 1] === ";") { while (j < n && src[j] !== "\n") j++; continue; }
      if (c === "(" && src[j + 1] === ";") { let dd = 1; j += 2; while (j < n && dd > 0) { if (src[j] === "(" && src[j + 1] === ";") { dd++; j += 2; } else if (src[j] === ";" && src[j + 1] === ")") { dd--; j += 2; } else j++; } continue; }
      if (c === "(") d++;
      else if (c === ")") { d--; j++; if (d === 0) break; continue; }
      j++;
    }
    emitModule(src.slice(i, j));
    i = j; continue;
  }
  i++;
}

process.stdout.write(String(count) + "\n");
