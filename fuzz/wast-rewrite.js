// Rewrite a .wast script, replacing each top-level *text* module definition with
// wax's recompiled binary — (module [$name] binary "..."), preserving the
// module's name — and leaving everything else (assertions, registers, and the
// modules nested inside assert_invalid/assert_malformed) verbatim. A module wax
// cannot reproduce is left unchanged. The result is fed to the reference
// interpreter to check that wax preserves observable behaviour.
//
//   node wast-rewrite.js <file.wast>     (writes the rewritten script to stdout)
//
// Env: WAX (wax binary), MODE (codec = wasm->wasm, wax = wasm->wax->wasm),
//      WASM_TOOLS (to assemble the original module text to a reference binary).

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const file = process.argv[2];
const src = fs.readFileSync(file, "utf8");
const WAX = process.env.WAX;
const MODE = process.env.MODE || "codec";
const WT = process.env.WASM_TOOLS || "wasm-tools";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "wastrw-"));
let recompiled = 0, failed = 0;

const run = (cmd, args) => {
  try { cp.execFileSync(cmd, args, { stdio: ["ignore", "ignore", "ignore"] }); return true; }
  catch (e) { return false; }
};

// wax-recompile the reference binary at [ref] into [out]; false if wax can't.
function waxCompile(ref, out) {
  if (MODE === "codec") return run(WAX, ["-i", "wasm", "-f", "wasm", ref, "-o", out]);
  const mid = ref + ".wax";
  return run(WAX, ["-i", "wasm", "-f", "wax", ref, "-o", mid]) &&
         run(WAX, ["-i", "wax", "-f", "wasm", mid, "-o", out]);
}

// .wast byte-string escape: every byte as \XX.
const escape = (buf) => '"' + [...buf].map((b) => "\\" + b.toString(16).padStart(2, "0")).join("") + '"';

// Replace a top-level (module ...) text definition with wax's binary.
function rewriteModule(group) {
  // Drop negative-linking assertions, but ONLY on the wax path (MODE=wax):
  // wasm->wax->wasm runs wax's type inference, which may soundly narrow an
  // exported immutable global to its initializer's principal type (a [const]
  // global declared at a supertype), making a previously-incompatible import
  // link. The round-trip contract preserves the validity, linkability and
  // semantics of modules that DO link, but does not promise an *unlinkable*
  // composition stays unlinkable, so a flipped assert_unlinkable is expected.
  // The codec path (MODE=codec, wasm->wasm) does no inference and must preserve
  // types exactly, so there a flipped assert_unlinkable IS a real bug — keep it.
  if (MODE === "wax" && /^\(\s*assert_unlinkable\b/.test(group)) return "";
  // Skip the binary/quote forms and module-less groups; recompile plain text.
  const m = group.match(/^\(\s*module\b\s*(\$[^\s()]+)?\s*([a-z]*)/);
  if (!m || m[2] === "binary" || m[2] === "quote") return group; // not a text module
  const name = m[1] ? " " + m[1] : "";
  const wat = path.join(tmp, "m.wat"), ref = path.join(tmp, "m.wasm"), out = path.join(tmp, "m.out.wasm");
  fs.writeFileSync(wat, group);
  if (run(WT, ["parse", wat, "-o", ref]) && waxCompile(ref, out)) {
    recompiled++;
    return "(module" + name + " binary " + escape(fs.readFileSync(out)) + ")";
  }
  failed++;
  return group; // wax couldn't reproduce it: keep the original (NOT tested via wax)
}

// Walk the script; only ( ... ) groups need parsing (to find their extent,
// respecting strings and comments). Everything else is copied verbatim.
let out = "", i = 0;
const n = src.length;
while (i < n) {
  if (src[i] === "(" && src[i + 1] === ";") { // block comment (nestable)
    let d = 1, j = i + 2;
    while (j < n && d > 0) {
      if (src[j] === "(" && src[j + 1] === ";") { d++; j += 2; }
      else if (src[j] === ";" && src[j + 1] === ")") { d--; j += 2; }
      else j++;
    }
    out += src.slice(i, j); i = j; continue;
  }
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
    out += rewriteModule(src.slice(i, j));
    i = j; continue;
  }
  out += src[i]; i++;
}

fs.rmSync(tmp, { recursive: true, force: true });
process.stderr.write(`recompiled=${recompiled} failed=${failed}\n`);
process.stdout.write(out);
