// Rewrite a .wast script, replacing each top-level *text* module definition with
// wax's recompiled binary — (module [$name] binary "..."), preserving the
// module's name — and leaving everything else (assertions, registers, and the
// modules nested inside assert_invalid/assert_malformed) verbatim. A module wax
// cannot reproduce is left unchanged. The result is fed to the reference
// interpreter to check that wax preserves observable behaviour.
//
//   node wast-rewrite.js <file.wast>     (writes the rewritten script to stdout)
//
// Env: WAX (wax binary), MODE (codec = wasm->wasm, wax = wasm->wax->wasm,
//      wax-text = wat->wax->wasm straight from the module's TEXT — the input
//      pipeline a wasm binary cannot exercise), WASM_TOOLS (to assemble the
//      original module text to a reference binary; unused by wax-text).

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const file = process.argv[2];
const src = fs.readFileSync(file, "utf8");
const WAX = process.env.WAX;
const MODE = process.env.MODE || "codec";
const WT = process.env.WASM_TOOLS || "wasm-tools";
// Semantics-preserving mutation mode (used by exec-mutate.sh). When MUTATE_SEED
// is set, each text module is replaced not by wax's recompilation but by a
// `wasm-tools mutate --preserve-semantics` variant of it — structurally novel
// yet behaviourally identical, so the script's assertions still hold. This turns
// the fixed spec suite into an endless supply of assertion-bearing modules to
// feed the behavioural oracle. Unset => the original wax/codec behaviour below,
// byte-for-byte.
const MUTATE_SEED = process.env.MUTATE_SEED;
const MUTATE_STEPS = parseInt(process.env.MUTATE_STEPS || "10", 10);
let modIndex = 0;

// Hostile-identifier mode (MODE=wax-text only). When HOSTILE_SEED is set, each
// module's WAT text has one identifier uniformly renamed to a spelling that
// stresses wax's name hygiene BEFORE it reaches wax: a name sanitize_identifier
// rejects (so it renders under a generated fallback), a name that collides with
// a generated fallback (l/x/f/t/g/m/e/d), or a Wax keyword. A uniform rename of
// one token to a fresh spelling is semantics-preserving, so the script's
// assertions still hold — unless wax mishandles the hostile name (e.g. an
// unsanitizable label collides with a generated one and a branch retargets).
const HOSTILE_SEED = process.env.HOSTILE_SEED;
// Unsanitizable first (runs of separators), then fallback-colliding, then
// keywords — the classes the name-hygiene passes must each survive.
const HOSTILE_NAMES = [
  "$a--b", "$--", "$!!!", "$..", "$<>",
  "$l", "$x", "$f", "$t", "$g", "$m", "$e", "$d",
  "$while", "$do", "$fn", "$let", "$if",
];
let hostileIndex = 0;

// Scan a WAT text, invoking [onId] for each $identifier token that is real code
// (outside string literals, line comments `;;`, and nestable block comments
// `(; ;)`) and [onOther] for every other run of characters. A `$` inside a
// string — e.g. an export name `(export "$")` — must not be mistaken for an
// identifier, or renaming would corrupt the export.
function scanWat(text, onId, onOther) {
  const isDelim = (c) => c === undefined || /[\s()";]/.test(c);
  let i = 0;
  const n = text.length;
  let run = 0; // start of the current pending onOther slice
  const flush = (end) => { if (end > run) onOther(text.slice(run, end)); };
  while (i < n) {
    const c = text[i];
    if (c === '"') { let j = i + 1; while (j < n && text[j] !== '"') { if (text[j] === "\\") j++; j++; } i = j + 1; continue; }
    if (c === ";" && text[i + 1] === ";") { while (i < n && text[i] !== "\n") i++; continue; }
    if (c === "(" && text[i + 1] === ";") { let d = 1; i += 2; while (i < n && d > 0) { if (text[i] === "(" && text[i + 1] === ";") { d += 1; i += 2; } else if (text[i] === ";" && text[i + 1] === ")") { d -= 1; i += 2; } else i++; } continue; }
    if (c === "$") { flush(i); let j = i + 1; while (j < n && !isDelim(text[j])) j++; onId(text.slice(i, j)); run = j; i = j; continue; }
    i++;
  }
  flush(n);
}

// Uniformly rename one $identifier (chosen by [seed]) to a hostile spelling not
// already present, returning the rewritten text. Whole-token, real-code only
// (never inside a string/comment). A no-op if there is no token, or no unused
// hostile name.
function hostileRename(text, seed) {
  const toks = new Set();
  scanWat(text, (id) => toks.add(id), () => {});
  const list = [...toks];
  if (list.length === 0) return text;
  const pick = list[seed % list.length];
  let repl = null;
  for (let i = 0; i < HOSTILE_NAMES.length; i++) {
    const cand = HOSTILE_NAMES[(seed + i) % HOSTILE_NAMES.length];
    if (!toks.has(cand)) { repl = cand; break; }
  }
  if (repl === null) return text;
  let out = "";
  scanWat(text, (id) => { out += id === pick ? repl : id; }, (s) => { out += s; });
  return out;
}

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

// Text-input round trip: wat -> wax -> wasm, straight from the module's WAT
// source [watFile]. Unlike waxCompile (which reads a wasm-tools-assembled
// binary), this drives from_wasm's *text* reader and the Wax surface
// printer/parser, where symbolic-vs-numeric references, unsanitizable
// identifiers, and width re-inference live — all of which a binary has already
// normalized away. False if either leg fails.
function waxCompileText(watFile, out) {
  const mid = out + ".wax";
  return run(WAX, ["-i", "wat", "-f", "wax", watFile, "-o", mid]) &&
         run(WAX, ["-i", "wax", "-f", "wasm", mid, "-o", out]);
}

// Semantics-preserving mutation of the reference binary [ref] into [out]:
// chain MUTATE_STEPS `wasm-tools mutate --preserve-semantics` passes (each a
// distinct, deterministic seed derived from MUTATE_SEED and the module index).
// Behaviour is preserved, so the script's assertions still hold on the result.
// Returns false if not even one pass applied (the module is then left as-is).
function mutate(ref, out) {
  const base = ((parseInt(MUTATE_SEED, 10) | 0) + modIndex * 1000) >>> 0;
  modIndex++;
  fs.copyFileSync(ref, out);
  const tmpf = out + ".m";
  let ok = false;
  for (let k = 0; k < MUTATE_STEPS; k++) {
    if (run(WT, ["mutate", out, "--preserve-semantics", "--seed", String(base + k), "-o", tmpf])) {
      fs.copyFileSync(tmpf, out);
      ok = true;
    } else break; // out of fuel / cannot mutate further: keep what we have
  }
  return ok;
}

// Transform one module's reference binary [ref] into [out]. Composes an optional
// semantics-preserving mutation (when MUTATE_SEED is set) with the MODE step:
//   MODE=mutate  -> emit the mutant as-is (mutate-only; used to baseline it);
//   MODE=wax     -> wax round-trip of the (possibly mutated) module;
//   MODE=codec   -> wasm->wasm of the (possibly mutated) module.
// A mutate-only run and a wax run over the SAME file derive identical per-module
// seeds (same order), so the wax run recompiles exactly the module the
// mutate-only run baselined — the two need not be chained through a .wast (which
// would not work: the mutant is embedded in binary form, which this rewriter
// leaves untouched).
function transformModule(ref, out) {
  let cur = ref;
  if (MUTATE_SEED !== undefined) {
    const mref = out + ".mut";
    if (!mutate(cur, mref)) return false; // could not mutate: leave module as-is
    cur = mref;
  }
  if (MODE === "mutate") { fs.copyFileSync(cur, out); return true; }
  return waxCompile(cur, out);
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
  // (Only on the wax recompile path; a semantics-preserving mutation keeps
  // linkability, so in mutate mode every assertion is kept.)
  if (!MUTATE_SEED && (MODE === "wax" || MODE === "wax-text") &&
      /^\(\s*assert_unlinkable\b/.test(group)) return "";
  // Skip the binary/quote forms and module-less groups; transform plain text.
  const m = group.match(/^\(\s*module\b\s*(\$[^\s()]+)?\s*([a-z]*)/);
  if (!m || m[2] === "binary" || m[2] === "quote") return group; // not a text module
  const name = m[1] ? " " + m[1] : "";
  const wat = path.join(tmp, "m.wat"), ref = path.join(tmp, "m.wasm"), out = path.join(tmp, "m.out.wasm");
  // Text-input path: feed the module's WAT source straight to wax, bypassing the
  // wasm-tools assembly the binary modes need. Optionally rename one identifier
  // to a hostile spelling first (semantics-preserving), to stress wax's name
  // hygiene on real modules with real assertions.
  if (MODE === "wax-text") {
    let text = group;
    if (HOSTILE_SEED !== undefined) {
      text = hostileRename(group, (parseInt(HOSTILE_SEED, 10) | 0) + hostileIndex);
      hostileIndex++;
    }
    fs.writeFileSync(wat, text);
    if (waxCompileText(wat, out)) {
      recompiled++;
      return "(module" + name + " binary " + escape(fs.readFileSync(out)) + ")";
    }
    failed++;
    return group;
  }
  fs.writeFileSync(wat, group);
  if (run(WT, ["parse", wat, "-o", ref]) && transformModule(ref, out)) {
    recompiled++;
    return "(module" + name + " binary " + escape(fs.readFileSync(out)) + ")";
  }
  failed++;
  return group; // could not transform it: keep the original (NOT tested)
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
