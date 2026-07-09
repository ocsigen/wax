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

  // WAT support shares the same wasm module. Formatting is idempotent, a syntax
  // error is rejected, a clean module has no diagnostics, and an invalid one
  // reports at least one error. (The clean module exports its function so the
  // unused-function lint does not fire.)
  const wat = wax.formatWat("(module (func $f (result i32) (i32.const 1)))");
  if (!wat.ok || wat.text === null) {
    throw new Error("web: unexpected WAT format result: " + JSON.stringify(wat));
  }
  if (wax.formatWat(wat.text).text !== wat.text) {
    throw new Error("web: WAT formatting is not idempotent: " + JSON.stringify(wat));
  }
  const badWat = wax.formatWat("(module (func");
  if (badWat.ok || badWat.text !== null) {
    throw new Error("web: WAT syntax error should have been rejected: " + JSON.stringify(badWat));
  }
  const cleanWat =
    '(module (func $f (result i32) (i32.const 1)) (export "f" (func $f)))';
  if (wax.checkWat(cleanWat).length !== 0) {
    throw new Error("web: clean WAT module should have no diagnostics");
  }
  const watDiags = wax.checkWat("(module (func (result i32)))");
  if (!watDiags.some((d) => d.severity === "error")) {
    throw new Error("web: expected a WAT validation error: " + JSON.stringify(watDiags));
  }

  // WAT outline: a named function and global become symbols (named by their id).
  const watSyms = wax.symbolsWat(
    "(module (global $g i32 (i32.const 0)) (func $f))",
  );
  if (
    watSyms.length !== 2 ||
    watSyms[0].name !== "$g" ||
    watSyms[0].kind !== "variable" ||
    watSyms[1].name !== "$f" ||
    watSyms[1].kind !== "function"
  ) {
    throw new Error("web: expected WAT outline symbols: " + JSON.stringify(watSyms));
  }

  // An id that is not a plain identifier is shown in the quoted $"…" form.
  const quotedSyms = wax.symbolsWat('(module (func $"a b"))');
  if (quotedSyms.length !== 1 || quotedSyms[0].name !== '$"a b"') {
    throw new Error("web: expected a quoted WAT id: " + JSON.stringify(quotedSyms));
  }

  // Conversion: Wax compiles to WAT and WAT decompiles to Wax; a round trip
  // preserves the function.
  const wat2 = wax.toWat("fn f() -> i32 { 1; }");
  if (!wat2.ok || wat2.text === null || !wat2.text.includes("func")) {
    throw new Error("web: unexpected toWat result: " + JSON.stringify(wat2));
  }
  const wax2 = wax.toWax(cleanWat);
  if (!wax2.ok || wax2.text === null || !wax2.text.includes("fn f(")) {
    throw new Error("web: unexpected toWax result: " + JSON.stringify(wax2));
  }
  // A conversion of un-typeable input reports an error rather than throwing.
  const bad2 = wax.toWat("fn f() -> i32 { }");
  if (bad2.ok) {
    throw new Error("web: toWat should reject an ill-typed module: " + JSON.stringify(bad2));
  }

  // The preview commands are registered.
  const commands = await vscode.commands.getCommands(true);
  for (const id of ["wax.showWat", "wax.showWax"]) {
    if (!commands.includes(id)) {
      throw new Error("web: command not registered: " + id);
    }
  }

  // Run "Show compiled WAT" end to end. Regression: an untitled document's path
  // has no leading slash, which made the preview URI construction throw a
  // UriError on the web host.
  const untitled = await vscode.workspace.openTextDocument({
    language: "wax",
    content: "fn f() -> i32 { 1; }",
  });
  await vscode.window.showTextDocument(untitled);
  await vscode.commands.executeCommand("wax.showWat");
  const preview = vscode.workspace.textDocuments.find(
    (d) => d.uri.scheme === "wax-preview",
  );
  if (!preview) {
    throw new Error("web: Show compiled WAT did not open a preview");
  }
  if (!preview.getText().includes("func")) {
    throw new Error("web: preview lacked compiled WAT: " + preview.getText());
  }

  console.log("WEB SMOKE TEST PASSED");
}
