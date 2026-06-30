// Differential execution oracle. Runs a wasm spec test's assertions against TWO
// copies of every module — the original and the one recompiled through wax — and
// reports where they behave differently. Comparing the two (rather than each to
// the spec's expected value) cancels out any limitation of this harness: a
// mismatch means wax changed the module's observable behaviour.
//
//   node exec-run.js <test.json> <orig-dir> <wax-dir>
//
// Output: one FAIL line per behavioural divergence, then a SUMMARY line. Exits
// non-zero on any divergence.

const fs = require("fs");
const path = require("path");

const [jsonPath, origDir, waxDir] = process.argv.slice(2);
const spec = JSON.parse(fs.readFileSync(jsonPath, "utf8"));

const f32a = new Float32Array(1), f32i = new Uint32Array(f32a.buffer);
const f64a = new Float64Array(1), f64i = new BigUint64Array(f64a.buffer);
const bitsToF32 = (b) => { f32i[0] = Number(BigInt.asUintN(32, BigInt(b))); return f32a[0]; };
const bitsToF64 = (b) => { f64i[0] = BigInt.asUintN(64, BigInt(b)); return f64a[0]; };
const f32ToBits = (x) => { f32a[0] = x; return BigInt(f32i[0] >>> 0); };
const f64ToBits = (x) => { f64a[0] = x; return f64i[0]; };

// Host references (the spec's `ref.host`/`ref.extern N`) are opaque values; in
// JS any value works. Intern one object per index, SHARED between the original
// and wax worlds, so passing "the same host ref" to both — and recognising it
// in a result — is stable. externref/anyref are the only ref types that carry a
// numeric host index in the spec JSON; every other ref value is "null".
const hostRefs = new Map();
const hostId = new Map();
function hostRef(n) {
  if (!hostRefs.has(n)) {
    const o = { host: n };
    hostRefs.set(n, o);
    hostId.set(o, n);
  }
  return hostRefs.get(n);
}
const isRefType = (t) => /ref/.test(t);

function toArg(v) {
  const nan = typeof v.value === "string" && v.value.startsWith("nan");
  switch (v.type) {
    case "i32": return { ok: true, val: Number(BigInt.asIntN(32, BigInt(v.value))) };
    case "i64": return { ok: true, val: BigInt.asIntN(64, BigInt(v.value)) };
    case "f32": return { ok: true, val: nan ? NaN : bitsToF32(v.value) };
    case "f64": return { ok: true, val: nan ? NaN : bitsToF64(v.value) };
    default:
      if (!isRefType(v.type)) return { ok: false };
      if (v.value === "null") return { ok: true, val: null };
      if ((v.type === "externref" || v.type === "anyref") && /^[0-9]+$/.test(v.value))
        return { ok: true, val: hostRef(v.value) };
      return { ok: false }; // a wasm-internal ref we cannot construct as an arg
  }
}

// A canonical, comparable encoding of one result value given its declared type.
// Returns null for values we cannot compare portably (v128, and wasm-internal
// references whose identity differs between the two instances) so the caller
// skips them.
function encode(type, v) {
  switch (type) {
    case "i32": return "i32:" + BigInt.asIntN(32, BigInt(v)).toString();
    case "i64": return "i64:" + BigInt.asIntN(64, BigInt(v)).toString();
    case "f32": return "f32:" + (Number.isNaN(v) ? "nan" : f32ToBits(v).toString());
    case "f64": return "f64:" + (Number.isNaN(v) ? "nan" : f64ToBits(v).toString());
    default:
      if (!isRefType(type)) return null;
      if (v === null || v === undefined) return "ref:null";
      if (hostId.has(v)) return "ref:host:" + hostId.get(v);
      return null; // internal wasm ref (func/struct/i31/...): not comparable
  }
}

// Does a result's bit pattern match a spec-expected float value, which may be a
// concrete bit pattern or a NaN category (nan:canonical / nan:arithmetic)?
function floatMatches(gotBits, expected, width) {
  const mantBits = BigInt(width === 32 ? 23 : 52);
  const expField = BigInt(width === 32 ? 8 : 11);
  const exp = (gotBits >> mantBits) & ((1n << expField) - 1n);
  const mant = gotBits & ((1n << mantBits) - 1n);
  const isNaN = exp === (1n << expField) - 1n && mant !== 0n;
  if (expected === "nan:canonical") return isNaN && mant === 1n << (mantBits - 1n);
  if (expected === "nan:arithmetic") return isNaN && (mant & (1n << (mantBits - 1n))) !== 0n;
  return BigInt.asUintN(width, gotBits) === BigInt.asUintN(width, BigInt(expected));
}

// Self-check: does an actual result match the spec's expected value? Returns
// null for value types we can't verify (v128, internal refs).
function matchesExpected(e, got) {
  switch (e.type) {
    case "i32": return BigInt.asIntN(32, BigInt(got)) === BigInt.asIntN(32, BigInt(e.value));
    case "i64": return BigInt.asIntN(64, BigInt(got)) === BigInt.asIntN(64, BigInt(e.value));
    case "f32": return floatMatches(f32ToBits(got), e.value, 32);
    case "f64": return floatMatches(f64ToBits(got), e.value, 64);
    default:
      if (!isRefType(e.type)) return null;
      if (e.value === "null") return got === null || got === undefined;
      if (hostId.has(got)) return hostId.get(got) === e.value;
      return null;
  }
}

const isTrapAssert = (t) =>
  t === "assert_trap" || t === "assert_exhaustion" || t === "assert_exception";

function spectestImports() {
  const nop = () => {};
  return { spectest: {
    print: nop, print_i32: nop, print_i64: nop, print_f32: nop, print_f64: nop,
    print_i32_f32: nop, print_f64_f64: nop,
    global_i32: 666, global_i64: 666n, global_f32: 0, global_f64: 0,
    table: new WebAssembly.Table({ initial: 10, maximum: 20, element: "anyfunc" }),
    memory: new WebAssembly.Memory({ initial: 1, maximum: 2 }),
  } };
}

let failures = 0, ranAsserts = 0, skippedAsserts = 0, waxUninstantiable = 0;
const fail = (m) => { failures++; console.log("FAIL " + m); };

// With two directories given we run differentially (original vs wax). With one,
// we self-check: run the original and compare to the spec's expected values —
// this validates the harness itself.
const selfCheck = waxDir === undefined;

// One world per side (original / wax): current instance + import registry.
const mk = () => ({ current: null, registry: {} });
const O = mk(), W = mk();

function instantiate(dir, file) {
  const bytes = fs.readFileSync(path.join(dir, file));
  return new WebAssembly.Instance(new WebAssembly.Module(bytes),
    Object.assign(spectestImports(), arguments[2])).exports;
}

// Run an action on a side; returns {trap:bool, results?:any[], ok:bool}.
// ok=false means an unsupported argument type — the assertion is skipped.
function run(side, action) {
  if (!side.current) return { ok: false };
  try {
    if (action.type === "get") {
      const g = side.current[action.field];
      return { ok: true, trap: false, results: [g && typeof g === "object" && "value" in g ? g.value : g] };
    }
    if (action.type !== "invoke") return { ok: false };
    const fn = side.current[action.field];
    if (typeof fn !== "function") return { ok: false };
    const args = (action.args || []).map(toArg);
    if (args.some((a) => !a.ok)) return { ok: false };
    const got = fn(...args.map((a) => a.val));
    return { ok: true, trap: false, results: Array.isArray(got) ? got : [got] };
  } catch (e) { return { ok: true, trap: true }; }
}

for (const cmd of spec.commands) {
  switch (cmd.type) {
    case "module":
      try { O.current = instantiate(origDir, cmd.filename, O.registry); }
      catch (e) { O.current = null; }
      if (!selfCheck) {
        try { W.current = instantiate(waxDir, cmd.filename, W.registry); }
        catch (e) { W.current = null; if (O.current) waxUninstantiable++; }
      }
      break;
    case "register":
      if (O.current) O.registry[cmd.as] = O.current;
      if (!selfCheck && W.current) W.registry[cmd.as] = W.current;
      break;
    case "action":
      run(O, cmd.action);
      if (!selfCheck) run(W, cmd.action); // side effects on both
      break;
    case "assert_return":
    case "assert_trap":
    case "assert_exhaustion":
    case "assert_exception": {
      if (!cmd.action || !O.current) { skippedAsserts++; break; }
      // A v128 result cannot cross the JS<->wasm boundary (the call throws), so
      // such assertions can't be run here at all — skip them.
      if ((cmd.expected || []).some((e) => e.type === "v128")) { skippedAsserts++; break; }
      if (selfCheck) {
        const ro = run(O, cmd.action);
        if (!ro.ok) { skippedAsserts++; break; }
        ranAsserts++;
        const where = `line ${cmd.line}: ${cmd.action.field || cmd.action.type}`;
        if (isTrapAssert(cmd.type)) {
          if (!ro.trap) fail(`${where}: expected a trap, but it returned`);
          break;
        }
        if (ro.trap) { fail(`${where}: trapped unexpectedly`); break; }
        const expected = cmd.expected || [];
        for (let i = 0; i < expected.length; i++) {
          const m = matchesExpected(expected[i], ro.results[i]);
          if (m === null) continue; // unverifiable value type
          if (!m) { fail(`${where}: result ${i}: expected ${expected[i].type} ${expected[i].value}, got ${ro.results[i]}`); break; }
        }
        break;
      }
      if (!W.current) { skippedAsserts++; break; } // wax couldn't build it
      const ro = run(O, cmd.action), rw = run(W, cmd.action);
      if (!ro.ok || !rw.ok) { skippedAsserts++; break; }
      ranAsserts++;
      const where = `line ${cmd.line}: ${cmd.action.field || cmd.action.type}`;
      if (ro.trap !== rw.trap) {
        fail(`${where}: original ${ro.trap ? "trapped" : "returned"}, wax ${rw.trap ? "trapped" : "returned"}`);
        break;
      }
      if (ro.trap) break; // both trapped: agree
      // Compare results element-wise, using the assertion's declared types.
      const types = (cmd.expected || []).map((e) => e.type);
      const n = Math.max(types.length, ro.results.length, rw.results.length);
      for (let i = 0; i < n; i++) {
        const t = types[i] || "i32";
        const a = encode(t, ro.results[i]);
        const b = encode(t, rw.results[i]);
        if (a === null || b === null) continue; // unsupported type
        if (a !== b) { fail(`${where}: result ${i}: original ${a}, wax ${b}`); break; }
      }
      break;
    }
    default: break;
  }
}

console.log(`SUMMARY ran=${ranAsserts} failed=${failures} skipped=${skippedAsserts} wax_uninstantiable=${waxUninstantiable}`);
process.exit(failures > 0 ? 1 : 0);
