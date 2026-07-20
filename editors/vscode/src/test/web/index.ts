// Web-host smoke test, run by @vscode/test-web inside the browser extension
// host (the same stack vscode.dev uses). It loads the wasm runtime directly so
// a load failure surfaces its actual error (the formatter provider would
// otherwise swallow it into the output channel).

import * as vscode from "vscode";
import { loadWax, WaxRange } from "../../wax-runtime";

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

  // check(): a valid module has no diagnostics; a broken one reports at least
  // one. (The clean module exports its function so the unused-function lint
  // does not fire.)
  if (wax.check("#[export]\nfn f() -> i32 { 1; }", []).length !== 0) {
    throw new Error("web: valid module should have no diagnostics");
  }
  const diags = wax.check("fn bad( {", []);
  if (diags.length === 0 || diags[0].severity !== "error") {
    throw new Error("web: expected an error diagnostic: " + JSON.stringify(diags));
  }

  // Related labels are surfaced: an unclosed delimiter points back at its opener.
  const unclosed = wax.check("fn f() -> i32 { (i32.add 1 2 }", []);
  if (unclosed.length === 0 || unclosed[0].related.length === 0) {
    throw new Error("web: expected a related label: " + JSON.stringify(unclosed));
  }

  // check() specialized to defines: a type error confined to the #[else] branch
  // is silenced when the defines pick the #[if] branch (mirroring `wax -D`), and
  // surfaces when they pick the #[else] branch.
  const condSrc =
    "fn f() -> i32 {\n" +
    "  let x: i32;\n" +
    "  #[if(debug)] { x = 1; }\n" +
    "  #[else] { x = 2.0; }\n" +
    "  x;\n" +
    "}";
  if (wax.check(condSrc, ["debug=true"]).some((d) => d.severity === "error")) {
    throw new Error(
      "web: #[else] type error should be silenced when debug=true: " +
        JSON.stringify(wax.check(condSrc, ["debug=true"])),
    );
  }
  if (!wax.check(condSrc, ["debug=false"]).some((d) => d.severity === "error")) {
    throw new Error("web: #[else] type error should surface when debug=false");
  }

  // Document outline: top-level definitions become symbols.
  const syms = wax.symbols("const c: i32 = 0;\nfn f() -> i32 { 1; }");
  if (syms.length !== 2 || syms[1].kind !== "function") {
    throw new Error("web: expected outline symbols: " + JSON.stringify(syms));
  }

  // --- Position-based language features, driven through the runtime. A "‸" in
  // the source marks the (zero-based) cursor; `at` strips it and returns the
  // position. These lock in the behaviour otherwise only checked by hand. ---
  const at = (marked: string) => {
    const i = marked.indexOf("‸");
    const before = marked.slice(0, i);
    const line = (before.match(/\n/g) || []).length;
    const character = before.length - (before.lastIndexOf("\n") + 1);
    return { src: marked.slice(0, i) + marked.slice(i + 1), line, character };
  };
  const names = (cs: { name: string }[]) => cs.map((c) => c.name);

  // hover: the inferred type of the expression under the cursor.
  {
    const p = at("fn f(x: i32) -> i32 {\n  ‸x;\n}\n");
    const h = wax.hover(p.src, p.line, p.character);
    if (!h || h.type !== "i32") {
      throw new Error("web: hover: " + JSON.stringify(h));
    }
  }

  // definition + find-references: a use links to its declaration, and the
  // declaration finds the declaration plus the use.
  {
    const p = at("fn add(a: i32) -> i32 { a; }\nfn g() -> i32 { ‸add(0); }\n");
    const defs = wax.definition(p.src, p.line, p.character);
    if (defs.length !== 1 || defs[0].startLine !== 0) {
      throw new Error("web: definition: " + JSON.stringify(defs));
    }
    const refs = wax.references(p.src, p.line, p.character);
    if (refs.length !== 2) {
      throw new Error("web: references: " + JSON.stringify(refs));
    }
  }

  // go-to-type-definition: from a value of type `&point`, jump to the `point`
  // type declaration (distinct from the value's own binding).
  {
    const p = at(
      "type point = { x: i32, y: i32 };\nfn g(q: &point) -> i32 { ‸q.x; }\n",
    );
    const td = wax.typeDefinition(p.src, p.line, p.character);
    if (td.length !== 1 || td[0].startLine !== 0 || td[0].startChar !== 5) {
      throw new Error("web: typeDefinition: " + JSON.stringify(td));
    }
    // A primitive-typed value has no type definition to jump to.
    const q = at("fn g() -> i32 { let n = ‸1; n; }\n");
    if (wax.typeDefinition(q.src, q.line, q.character).length !== 0) {
      throw new Error("web: typeDefinition should be empty for a primitive");
    }
  }

  // completion: names in scope, scoped to the cursor — a `let` bound after it is
  // not offered — plus the always-in-scope module definitions and parameters.
  {
    const p = at(
      "const c: i32 = 0;\nfn f(a: i32) {\n  let x = 1;\n‸  let y = 2;\n}\n",
    );
    const n = names(wax.completion(p.src, p.line, p.character, []));
    for (const want of ["c", "f", "a", "x"]) {
      if (!n.includes(want)) {
        throw new Error("web: completion missing " + want + ": " + n);
      }
    }
    if (n.includes("y")) {
      throw new Error("web: completion offered out-of-scope y: " + n);
    }
  }

  // completion specialized to defines: a definition in the branch the
  // configuration rules out is not offered (mirroring `wax -D`); without defines
  // both branches' names are offered.
  {
    const p = at(
      "#[if(debug)] { fn dbg() {} }\n#[else] { fn rel() {} }\nfn use_it() {\n‸}\n",
    );
    const both = names(wax.completion(p.src, p.line, p.character, []));
    if (!both.includes("dbg") || !both.includes("rel")) {
      throw new Error("web: no-define completion should offer both: " + both);
    }
    const on = names(wax.completion(p.src, p.line, p.character, ["debug=true"]));
    if (!on.includes("dbg") || on.includes("rel")) {
      throw new Error("web: debug=true should offer dbg, not rel: " + on);
    }
    const off = names(
      wax.completion(p.src, p.line, p.character, ["debug=false"]),
    );
    if (!off.includes("rel") || off.includes("dbg")) {
      throw new Error("web: debug=false should offer rel, not dbg: " + off);
    }
  }

  // member completion after ".": a struct's fields, and a numeric receiver's
  // value methods.
  {
    const p = at("type p = { x: i32, y: i32 };\nfn g(q: &p) {\n  _ = q.‸x;\n}\n");
    const n = names(wax.completion(p.src, p.line, p.character, []));
    if (!n.includes("x") || !n.includes("y")) {
      throw new Error("web: member completion: " + n);
    }
  }
  {
    const p = at("fn m(v: f32) {\n  _ = v.‸s;\n}\n");
    if (!names(wax.completion(p.src, p.line, p.character, [])).includes("sqrt")) {
      throw new Error("web: value-method completion missing sqrt");
    }
  }
  // completion after "::": an intrinsic namespace's members.
  {
    const p = at("fn m() {\n  _ = i64::‸a;\n}\n");
    if (!names(wax.completion(p.src, p.line, p.character, [])).includes("add128")) {
      throw new Error("web: namespace completion missing add128");
    }
  }

  // signature help: the callee's signature with the active argument, for a
  // function call and — thanks to error recovery auto-closing — an unclosed one.
  {
    const p = at("fn add(a: i32, b: i32) -> i32 { a; }\nfn m() { _ = add(1, ‸2); }\n");
    const s = wax.signatureHelp(p.src, p.line, p.character);
    if (!s || s.label !== "fn(a: i32, b: i32) -> i32" || s.active !== 1) {
      throw new Error("web: signatureHelp: " + JSON.stringify(s));
    }
  }
  {
    const p = at("fn add(a: i32, b: i32) {}\nfn m() {\n  add(1, ‸\n}\n");
    const s = wax.signatureHelp(p.src, p.line, p.character);
    if (!s || s.active !== 1) {
      throw new Error("web: signatureHelp (unclosed): " + JSON.stringify(s));
    }
  }
  {
    // A nested call resolves to the innermost callee under the cursor (the
    // distinct return types make the inner-vs-outer choice observable).
    const p = at(
      "fn f(a: i32) -> i32 { a; }\nfn g(x: f64) -> f64 { x; }\nfn m() { _ = f(g(‸)); }\n",
    );
    const s = wax.signatureHelp(p.src, p.line, p.character);
    if (!s || s.label !== "fn(x: f64) -> f64") {
      throw new Error("web: signatureHelp (nested): " + JSON.stringify(s));
    }
  }

  // semantic tokens: identifiers classified by role — a function name, a
  // parameter (definition and use), a type (definition and reference), a struct
  // field access.
  {
    const src =
      "type t = { f: i32 };\nfn g(a: i32) -> i32 { a; }\nfn h(p: &t) -> i32 { p.f; }\n";
    const lines = src.split("\n");
    const set = new Set(
      wax
        .semanticTokens(src)
        .map(
          (t) => lines[t.line].slice(t.character, t.character + t.length) + ":" + t.kind,
        ),
    );
    for (const want of [
      "t:type",
      "g:function",
      "a:parameter",
      "p:parameter",
      "f:property",
    ]) {
      if (!set.has(want)) {
        throw new Error("web: semantic token missing " + want + ": " + [...set]);
      }
    }
  }

  // folding ranges: a multi-line block comment folds as a comment region, and a
  // multi-line function body folds as a region.
  {
    const src = "/* a\n   block comment */\nfn g() -> i32 {\n  1\n}\n";
    const folds = wax.foldingRanges(src);
    const has = (start: number, end: number, kind: string) =>
      folds.some(
        (f) => f.startLine === start && f.endLine === end && f.kind === kind,
      );
    if (!has(0, 1, "comment")) {
      throw new Error("web: foldingRanges missing comment: " + JSON.stringify(folds));
    }
    if (!has(2, 4, "region")) {
      throw new Error("web: foldingRanges missing function: " + JSON.stringify(folds));
    }
  }

  // selection ranges: from a cursor on the identifier `a` inside `a + 1`, the
  // enclosing spans grow innermost-first — the identifier, then the `a + 1`
  // expression, … out to the whole file — each strictly containing the last.
  {
    const p = at("fn g(a: i32) -> i32 {\n  a‸ + 1\n}\n");
    const chain = wax.selectionRange(p.src, p.line, p.character);
    if (chain.length < 3) {
      throw new Error("web: selectionRange too short: " + JSON.stringify(chain));
    }
    const before = (o: WaxRange, i: WaxRange) =>
      o.startLine < i.startLine ||
      (o.startLine === i.startLine && o.startChar <= i.startChar);
    const after = (o: WaxRange, i: WaxRange) =>
      o.endLine > i.endLine ||
      (o.endLine === i.endLine && o.endChar >= i.endChar);
    for (let i = 1; i < chain.length; i++) {
      const inner = chain[i - 1];
      const outer = chain[i];
      const strict =
        before(outer, inner) &&
        after(outer, inner) &&
        !(
          outer.startChar === inner.startChar &&
          outer.startLine === inner.startLine &&
          outer.endChar === inner.endChar &&
          outer.endLine === inner.endLine
        );
      if (!strict) {
        throw new Error(
          "web: selectionRange not strictly nested at " +
            i +
            ": " +
            JSON.stringify(chain),
        );
      }
    }
    const first = chain[0];
    if (
      first.startLine !== 1 ||
      first.endLine !== 1 ||
      first.endChar - first.startChar !== 1
    ) {
      throw new Error(
        "web: selectionRange innermost should be the identifier `a`: " +
          JSON.stringify(first),
      );
    }
    const last = chain[chain.length - 1];
    if (last.startLine !== 0 || last.startChar !== 0) {
      throw new Error(
        "web: selectionRange outermost should be the whole file: " +
          JSON.stringify(last),
      );
    }
  }

  // inactive-branch ranges: a define makes the opposite branch dead; the range
  // spans the whole `#[else] { … }` (marker and closing brace included).
  {
    const src = "#[if(debug)] {\n  fn a() {}\n}\n#[else] {\n  fn b() {}\n}\n";
    if (wax.inactiveRanges(src, []).length !== 0) {
      throw new Error("web: inactiveRanges should be empty with no define");
    }
    const dead = wax.inactiveRanges(src, ["debug=true"]);
    if (
      dead.length !== 1 ||
      dead[0].startLine !== 3 ||
      dead[0].startChar !== 0 ||
      dead[0].endLine !== 5 ||
      dead[0].endChar !== 1
    ) {
      throw new Error("web: inactiveRanges(debug=true): " + JSON.stringify(dead));
    }
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
  for (const id of ["wax.showWat", "wax.showWax", "wax.configureDefines"]) {
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

  // Editing the source to be invalid keeps the last successful conversion in the
  // preview, marked stale, rather than blanking it to an error.
  const edit = new vscode.WorkspaceEdit();
  edit.replace(
    untitled.uri,
    new vscode.Range(
      untitled.positionAt(0),
      untitled.positionAt(untitled.getText().length),
    ),
    "fn f( {",
  );
  await vscode.workspace.applyEdit(edit);
  let stale = preview.getText();
  for (let i = 0; i < 100 && !stale.includes("⚠"); i++) {
    await new Promise((r) => setTimeout(r, 20));
    stale = preview.getText();
  }
  if (!stale.includes("⚠") || !stale.includes("func")) {
    throw new Error("web: stale preview should keep the last good output: " + stale);
  }

  console.log("WEB SMOKE TEST PASSED");
}
