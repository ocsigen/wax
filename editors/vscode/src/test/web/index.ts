// Web-host smoke test, run by @vscode/test-web inside the browser extension
// host (the same stack vscode.dev uses). It loads the wasm runtime directly so
// a load failure surfaces its actual error (the formatter provider would
// otherwise swallow it into the output channel).

import * as vscode from "vscode";
import { loadWax } from "../../wax-runtime";

const EXPECTED = "fn f(x: i32) -> i32 {\n    x;\n}\n";

export async function run(): Promise<void> {
  const ext = vscode.extensions.getExtension("wax-wasm.wax");
  if (!ext) throw new Error("extension wax-wasm.wax not found");
  await ext.activate();

  const context = {
    extensionUri: ext.extensionUri,
    subscriptions: [] as vscode.Disposable[],
  } as unknown as vscode.ExtensionContext;

  let wax;
  try {
    wax = await loadWax(context, {});
  } catch (e) {
    const detail = e instanceof Error ? e.stack || e.message : String(e);
    throw new Error("loadWax failed in web host:\n" + detail);
  }

  const ok = wax.format("fn   f( x:i32 )->i32{  x;  }");
  if (!ok.ok || ok.text !== EXPECTED) {
    throw new Error("web: unexpected format result: " + JSON.stringify(ok));
  }

  const bad = wax.format("fn bad( {");
  if (bad.ok || bad.text !== null) {
    throw new Error("web: syntax error should have been rejected: " + JSON.stringify(bad));
  }

  // check(): a valid module has no diagnostics; a broken one reports at least one.
  if (wax.check("fn f() -> i32 { 1; }").length !== 0) {
    throw new Error("web: valid module should have no diagnostics");
  }
  const diags = wax.check("fn bad( {");
  if (diags.length === 0 || diags[0].severity !== "error") {
    throw new Error("web: expected an error diagnostic: " + JSON.stringify(diags));
  }

  // Related labels are surfaced: an unclosed delimiter points back at its opener.
  const unclosed = wax.check("fn f() -> i32 { (i32.add 1 2 }");
  if (unclosed.length === 0 || unclosed[0].related.length === 0) {
    throw new Error("web: expected a related label: " + JSON.stringify(unclosed));
  }

  // Document outline: top-level definitions become symbols.
  const syms = wax.symbols("const c: i32 = 0;\nfn f() -> i32 { 1; }");
  if (syms.length !== 2 || syms[1].kind !== "function") {
    throw new Error("web: expected outline symbols: " + JSON.stringify(syms));
  }

  console.log("WEB SMOKE TEST PASSED");
}
