#!/usr/bin/env node
// Playground bundle smoke test (PLAYGROUND.md, Testing). Loads the wasm loader
// exactly as the playground page does — read the loader text, serve its .wasm
// through a fetch shim, run it in a Function, poll for globalThis.wax — and
// asserts a conversion round-trips. Run in the deploy job before publishing, so
// a broken bundle fails the deploy rather than the visitor. Mirrors the smoke
// test in npm/build.sh.
//
// Usage: node docs/tools/playground/smoke.js [PLAYGROUND_DIR]
//   PLAYGROUND_DIR defaults to docs/src/playground.

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const dir = process.argv[2] || path.join("docs", "src", "playground");
const loaderPath = path.join(dir, "wax_format_js.bc.wasm.js");

function fail(msg) {
  console.error("smoke: " + msg);
  process.exit(1);
}

function wasmNameFromLoader(src) {
  const m = src.match(/"link":\s*\[\s*\[\s*"([^"]+)"/);
  if (!m) fail("could not find the wasm module name in the loader");
  return m[1] + ".wasm";
}

function waitForGlobal(name, timeoutMs) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    (function tick() {
      const v = globalThis[name];
      if (v) return resolve(v);
      if (Date.now() - start > timeoutMs)
        return reject(new Error(`runtime did not initialise in ${timeoutMs}ms`));
      setTimeout(tick, 10);
    })();
  });
}

async function main() {
  if (!fs.existsSync(loaderPath)) fail("loader not found at " + loaderPath);
  const loaderSrc = fs.readFileSync(loaderPath, "utf8");
  const wasmName = wasmNameFromLoader(loaderSrc);
  const wasmBytes = fs.readFileSync(
    path.join(dir, "wax_format_js.bc.wasm.assets", wasmName)
  );

  // Serve the .wasm from memory; the loader takes its fetch branch.
  const previous = Object.getOwnPropertyDescriptor(globalThis, "fetch");
  globalThis.fetch = async (input) => {
    if (String(input).endsWith(".wasm")) {
      return new Response(wasmBytes, {
        headers: { "content-type": "application/wasm" },
      });
    }
    throw new Error("unexpected fetch for " + String(input));
  };

  // The loader chooses its Node vs browser (fetch) branch by probing
  // `process.versions.node`. The playground runs the fetch branch, so hide
  // `process` to exercise the exact code path the page uses.
  const prevProcess = Object.getOwnPropertyDescriptor(globalThis, "process");
  Object.defineProperty(globalThis, "process", {
    value: undefined,
    configurable: true,
  });

  try {
    new Function("require", loaderSrc)(undefined);
    const wax = await waitForGlobal("wax", 15000);

    const src = "#[export = \"add\"]\nfn add(x: i32, y: i32) -> i32 {\n    x + y;\n}\n";
    const result = wax.toWat(src);
    if (!result.ok || !result.text) fail("toWat failed: " + (result.error || "no output"));
    if (!result.text.includes("i32.add")) fail("unexpected WAT output:\n" + result.text);

    const diags = wax.check(src, []);
    if (!Array.isArray(diags)) fail("check did not return an array");

    // The binary-input path is the subtlest marshalling: bytes packed
    // one-per-char through a JS string into Js.to_bytestring. Feed it the 8-byte
    // empty module (\0asm + version 1) and assert it decodes.
    const emptyModule = "\x00asm\x01\x00\x00\x00";
    const wat = wax.wasmToWat(emptyModule);
    if (!wat.ok) fail("wasmToWat on the empty module failed: " + (wat.error || ""));
    const wax2 = wax.wasmToWax(emptyModule);
    if (!wax2.ok) fail("wasmToWax on the empty module failed: " + (wax2.error || ""));

    // The examples file, when present, must be a non-empty array.
    const examplesPath = path.join(dir, "examples.json");
    if (fs.existsSync(examplesPath)) {
      const examples = JSON.parse(fs.readFileSync(examplesPath, "utf8"));
      if (!Array.isArray(examples) || examples.length === 0)
        fail("examples.json is empty or not an array");
    }

    // The keyword list, when present, must be a non-empty array of strings.
    const keywordsPath = path.join(dir, "keywords.json");
    if (fs.existsSync(keywordsPath)) {
      const kws = JSON.parse(fs.readFileSync(keywordsPath, "utf8"));
      if (!Array.isArray(kws) || kws.length === 0 || !kws.every((k) => typeof k === "string"))
        fail("keywords.json is empty or not an array of strings");
    }

    // The CodeMirror editor bundle, when present, must evaluate and install
    // WaxCM.createWaxEditor. (It needs a DOM to construct an editor, so this
    // only checks that the bundle loads and exposes its entry point.)
    const editorPath = path.join(dir, "wax-editor.bundle.js");
    if (fs.existsSync(editorPath)) {
      const sandbox = { globalThis: {} };
      sandbox.globalThis = sandbox;
      vm.runInNewContext(fs.readFileSync(editorPath, "utf8"), sandbox);
      if (typeof (sandbox.WaxCM && sandbox.WaxCM.createWaxEditor) !== "function")
        fail("wax-editor.bundle.js did not install WaxCM.createWaxEditor");
    }

    console.log("smoke: OK (" + result.text.split("\n").length + " lines of WAT)");
  } finally {
    if (previous) Object.defineProperty(globalThis, "fetch", previous);
    else delete globalThis.fetch;
    if (prevProcess) Object.defineProperty(globalThis, "process", prevProcess);
  }
}

main().catch((e) => fail(e.stack || String(e)));
