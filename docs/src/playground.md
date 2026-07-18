<!-- The browser playground (PLAYGROUND.md, Phase 1). Runs the Wax toolchain
     itself as WebAssembly — the same wax_format_js bundle the VS Code web
     extension ships — so conversion and diagnostics happen entirely in the
     visitor's browser, with no server.

     This is a raw-HTML mdbook page: it inherits the site theme, nav and dark
     mode. All playground styling is scoped under #wax-playground. The wasm
     loader + module and examples.json are copied into src/playground/ at
     deploy time (see .github/workflows/deploy.yml); they are not committed. -->

# Playground

<div id="wax-playground" data-unsupported="Your browser cannot run the Wax toolchain: it needs WebAssembly GC support (any current Chrome, Firefox, Safari or Edge).">

<div class="wp-toolbar">
  <label class="wp-field">
    Direction
    <select id="wp-direction">
      <option value="wax" selected>Wax → WAT</option>
      <option value="wat">WAT → Wax</option>
    </select>
  </label>
  <label class="wp-field" id="wp-mode-field">
    Output
    <select id="wp-mode">
      <option value="wat" selected>WAT</option>
      <option value="wax">Wax (formatted)</option>
    </select>
  </label>
  <label class="wp-field">
    Example
    <select id="wp-example"><option value="">Load an example…</option></select>
  </label>
  <!-- Format acts on the source (left) pane, so it lives with the left-hand
       controls rather than out on the right. -->
  <button type="button" id="wp-format" class="wp-button">Format source</button>
  <span class="wp-spacer"></span>
  <button type="button" id="wp-share" class="wp-button"
          title="Copies a URL that reopens this playground with your current code. The code is encoded in the link itself and never sent to a server.">Copy link to this code</button>
</div>

<div class="wp-panes">
  <div class="wp-pane">
    <div class="wp-pane-title" id="wp-src-title">Wax source</div>
    <div class="wp-editor" id="wp-editor-host"></div>
  </div>
  <div class="wp-pane">
    <div class="wp-pane-title" id="wp-out-title">WAT output</div>
    <pre class="wp-output" id="wp-output"><code></code></pre>
  </div>
</div>

<div class="wp-status" id="wp-status">Loading the Wax toolchain…</div>
<ul class="wp-diagnostics" id="wp-diagnostics"></ul>

</div>

<style>
#wax-playground {
  /* Break out of mdbook's narrow content column into a wide two-pane layout. */
  position: relative;
  left: 50%;
  transform: translateX(-50%);
  width: 92vw;
  max-width: 1200px;
  box-sizing: border-box;
}
#wax-playground * { box-sizing: border-box; }

/* mdbook sets `html { font-size: 62.5% }` (1rem = 10px), so all sizes here are
   in em, relative to the body's readable base the page inherits. */
.wp-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 0.75em;
  margin-bottom: 0.75em;
}
.wp-field {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
  font-size: 0.8em;
  opacity: 0.85;
}
.wp-field select {
  font-size: 1.1em;
  padding: 0.3em 0.4em;
}
.wp-spacer { flex: 1 1 auto; }
.wp-button {
  padding: 0.4em 0.8em;
  font-size: 0.9em;
  cursor: pointer;
}
.wp-button:disabled { opacity: 0.5; cursor: default; }

.wp-panes {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1em;
}
@media (max-width: 760px) {
  .wp-panes { grid-template-columns: 1fr; }
}
.wp-pane { display: flex; flex-direction: column; min-width: 0; }
.wp-pane-title {
  font-size: 0.8em;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  opacity: 0.7;
  margin-bottom: 0.4em;
}

/* Shared metrics so the textarea and its highlight mirror line up exactly.
   The font size is the book's own code size, so the panes match the code
   blocks on every other page. */
.wp-editor, .wp-output {
  --wp-font: var(--mono-font, "Source Code Pro", Consolas, monospace);
  --wp-size: var(--code-font-size, 0.875em);
  --wp-line: 1.5;
  --wp-pad: 0.6em;
}
.wp-editor {
  position: relative;
  height: 60vh;
  min-height: 300px;
  border: 1px solid rgba(128, 128, 128, 0.4);
  border-radius: 4px;
  overflow: hidden;
}
/* CodeMirror fills the editor container and manages its own scrolling. */
.wp-editor .cm-editor { height: 100%; }
.wp-editor .cm-scroller { font-family: var(--wp-font); }

/* Plain-textarea fallback, used only if the CodeMirror bundle fails to load. */
.wp-input {
  position: absolute;
  inset: 0;
  margin: 0;
  padding: var(--wp-pad);
  border: 0;
  resize: none;
  background: transparent;
  color: var(--fg, inherit);
  caret-color: var(--fg, currentColor);
  font-family: var(--wp-font);
  font-size: var(--wp-size);
  line-height: var(--wp-line);
  white-space: pre;
  overflow: auto;
  tab-size: 4;
}
.wp-input:focus { outline: none; }

/* Semantic-token colours. These come from the toolchain (wax.semanticTokens),
   not a grammar, so highlighting always agrees with the type checker. A
   One-Light-ish palette by default, One-Dark-ish on mdbook's dark themes, so
   tokens stay legible whichever theme the reader picked. */
.cm-wt-namespace { color: #a626a4; }
.cm-wt-type      { color: #b76a2f; }
.cm-wt-function  { color: #4078f2; }
.cm-wt-property  { color: #0184bc; }
.cm-wt-parameter { color: #986801; }
.cm-wt-keyword   { color: #a626a4; }
.cm-wt-string    { color: #50a14f; }
.cm-wt-number    { color: #986801; }
.cm-wt-comment   { color: #a0a1a7; font-style: italic; }
html.coal .cm-wt-namespace, html.navy .cm-wt-namespace, html.ayu .cm-wt-namespace { color: #c678dd; }
html.coal .cm-wt-type, html.navy .cm-wt-type, html.ayu .cm-wt-type { color: #e5c07b; }
html.coal .cm-wt-function, html.navy .cm-wt-function, html.ayu .cm-wt-function { color: #61afef; }
html.coal .cm-wt-property, html.navy .cm-wt-property, html.ayu .cm-wt-property { color: #56b6c2; }
html.coal .cm-wt-parameter, html.navy .cm-wt-parameter, html.ayu .cm-wt-parameter { color: #d19a66; }
html.coal .cm-wt-keyword, html.navy .cm-wt-keyword, html.ayu .cm-wt-keyword { color: #c678dd; }
html.coal .cm-wt-string, html.navy .cm-wt-string, html.ayu .cm-wt-string { color: #98c379; }
html.coal .cm-wt-number, html.navy .cm-wt-number, html.ayu .cm-wt-number { color: #d19a66; }
html.coal .cm-wt-comment, html.navy .cm-wt-comment, html.ayu .cm-wt-comment { color: #7f848e; }

/* Inlay hints (inferred `let` types), document highlight, and the feature
   tooltips (hover type, signature help). */
.cm-wt-inlay { opacity: 0.55; font-style: italic; font-size: 0.9em; padding: 0 0.15em; }
.cm-wt-refhl { background: rgba(128, 128, 128, 0.22); border-radius: 2px; }
.cm-wt-hover, .cm-wt-sig {
  font-family: var(--wp-font);
  font-size: 0.95em;
  white-space: pre-wrap;
}
.cm-wt-sig-active { font-weight: bold; }
/* Tooltip/caret/selection colours live in the CodeMirror theme (editor.mjs), so
   they outrank CodeMirror's runtime-injected base theme. */

.wp-output {
  flex: 1 1 auto;
  height: 60vh;
  min-height: 300px;
  margin: 0;
  padding: var(--wp-pad);
  border: 1px solid rgba(128, 128, 128, 0.4);
  border-radius: 4px;
  overflow: auto;
  font-family: var(--wp-font);
  font-size: var(--wp-size);
  line-height: var(--wp-line);
  white-space: pre;
  tab-size: 4;
}

.wp-status {
  margin-top: 0.6em;
  font-size: 0.85em;
  opacity: 0.8;
  min-height: 1.2em;
}
.wp-status.wp-status-error { color: #e45649; opacity: 1; }

.wp-diagnostics { list-style: none; margin: 0.4em 0 0; padding: 0; }
.wp-diagnostics li {
  padding: 0.35em 0.5em;
  border-left: 3px solid transparent;
  cursor: pointer;
  font-size: 0.85em;
}
.wp-diagnostics li:hover { background: rgba(128, 128, 128, 0.12); }
.wp-diagnostics li.wp-d-error { border-left-color: #e45649; }
.wp-diagnostics li.wp-d-warning { border-left-color: #d19a2a; }
.wp-diagnostics li.wp-d-suggestion { border-left-color: #4078f2; }
.wp-diagnostics .wp-d-loc { opacity: 0.6; margin-right: 0.5em; font-variant-numeric: tabular-nums; }
.wp-diagnostics .wp-d-hint { display: block; opacity: 0.75; margin-top: 0.15em; font-style: italic; }
.wp-diagnostics .wp-d-related { display: block; opacity: 0.65; margin-top: 0.15em; padding-left: 1em; }

#wax-playground.wp-unsupported .wp-panes,
#wax-playground.wp-unsupported .wp-toolbar,
#wax-playground.wp-unsupported .wp-diagnostics { display: none; }
</style>

<script>
(function () {
  "use strict";

  var root = document.getElementById("wax-playground");
  if (!root) return;

  var els = {
    direction: document.getElementById("wp-direction"),
    modeField: document.getElementById("wp-mode-field"),
    mode: document.getElementById("wp-mode"),
    example: document.getElementById("wp-example"),
    format: document.getElementById("wp-format"),
    share: document.getElementById("wp-share"),
    host: document.getElementById("wp-editor-host"),
    output: document.getElementById("wp-output").querySelector("code"),
    srcTitle: document.getElementById("wp-src-title"),
    outTitle: document.getElementById("wp-out-title"),
    status: document.getElementById("wp-status"),
    diagnostics: document.getElementById("wp-diagnostics"),
  };

  var DEFAULT_SRC =
    '#[export = "add"]\n' +
    "fn add(x: i32, y: i32) -> i32 {\n" +
    "    x + y;\n" +
    "}\n";

  var wax = null;
  var editor = null; // the source editor (CodeMirror, or a textarea fallback)
  var waxKeywords = []; // Wax keyword list, from playground/keywords.json

  // ---- The wasm loader (mirrors editors/vscode/src/wax-runtime.ts, web branch).
  // The loader fetches its own .wasm; we serve the bytes from memory via a fetch
  // shim so no relative-URL heuristic has to be right on this page.

  var ASSET_DIR = "playground/";
  var LOADER = ASSET_DIR + "wax_format_js.bc.wasm.js";

  function wasmNameFromLoader(src) {
    var m = src.match(/"link":\s*\[\s*\[\s*"([^"]+)"/);
    if (!m) throw new Error("could not find the wasm module name in the loader");
    return m[1] + ".wasm";
  }

  function installFetchShim(bytes) {
    var previous = Object.getOwnPropertyDescriptor(globalThis, "fetch");
    globalThis.fetch = function (input) {
      if (String(input).endsWith(".wasm")) {
        return Promise.resolve(
          new Response(bytes, { headers: { "content-type": "application/wasm" } })
        );
      }
      throw new Error("wax: unexpected fetch for " + String(input));
    };
    return function () {
      if (previous) Object.defineProperty(globalThis, "fetch", previous);
      else delete globalThis.fetch;
    };
  }

  function waitForGlobal(name, timeoutMs) {
    return new Promise(function (resolve, reject) {
      var start = Date.now();
      (function tick() {
        var v = globalThis[name];
        if (v) return resolve(v);
        if (Date.now() - start > timeoutMs)
          return reject(new Error("runtime did not initialise in " + timeoutMs + "ms"));
        setTimeout(tick, 10);
      })();
    });
  }

  async function loadWax() {
    var loaderSrc = await (await fetch(LOADER)).text();
    var wasmName = wasmNameFromLoader(loaderSrc);
    var wasmBytes = new Uint8Array(
      await (await fetch(ASSET_DIR + "wax_format_js.bc.wasm.assets/" + wasmName)).arrayBuffer()
    );
    var restore = installFetchShim(wasmBytes);
    try {
      new Function("require", loaderSrc)(undefined);
      return await waitForGlobal("wax", 15000);
    } finally {
      restore();
    }
  }

  // ---- The CodeMirror editor bundle (docs/tools/playground, built by esbuild).
  // Self-hosted beside the page; installs globalThis.WaxCM. Best-effort: if it
  // fails to load, the page falls back to a plain textarea.

  function loadEditorBundle() {
    if (globalThis.WaxCM) return Promise.resolve(true);
    return new Promise(function (resolve) {
      var s = document.createElement("script");
      s.src = ASSET_DIR + "wax-editor.bundle.js";
      s.onload = function () { resolve(!!globalThis.WaxCM); };
      s.onerror = function () { resolve(false); };
      document.head.appendChild(s);
    });
  }

  // ---- Share links: source deflated into the URL fragment (never sent to a
  // server). CompressionStream keeps long snippets compact.

  function toBase64Url(bytes) {
    var s = "";
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  function fromBase64Url(str) {
    var s = str.replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) s += "=";
    var bin = atob(s);
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  async function deflate(text) {
    var cs = new CompressionStream("deflate-raw");
    var w = cs.writable.getWriter();
    w.write(new TextEncoder().encode(text));
    w.close();
    var buf = await new Response(cs.readable).arrayBuffer();
    return toBase64Url(new Uint8Array(buf));
  }
  async function inflate(b64) {
    var ds = new DecompressionStream("deflate-raw");
    var w = ds.writable.getWriter();
    w.write(fromBase64Url(b64));
    w.close();
    return await new Response(ds.readable).text();
  }

  function readFragment() {
    var m = /(?:^|[#&])code=([^&]+)/.exec(location.hash);
    var dir = /(?:^|[#&])dir=(wax|wat)/.exec(location.hash);
    return { code: m ? m[1] : null, dir: dir ? dir[1] : null };
  }

  // ---- line/char <-> offset (only the textarea fallback needs this; the
  // CodeMirror backend maps positions with its own document API).

  function offsetOf(text, line, ch) {
    var off = 0, l = 0;
    for (var i = 0; i < text.length && l < line; i++) {
      if (text.charCodeAt(i) === 10) l++;
      off = i + 1;
    }
    return off + ch;
  }

  function currentSourceIsWat() {
    return els.direction.value === "wat";
  }

  // ---- Output highlighting: colour the read-only output with the same
  // semantic tokens the editor uses, so both panes agree with the toolchain.

  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function highlightToHtml(text, tokens) {
    var starts = [0];
    for (var i = 0; i < text.length; i++) {
      if (text.charCodeAt(i) === 10) starts.push(i + 1);
    }
    var marks = [];
    tokens.forEach(function (t) {
      if (t.line >= starts.length) return;
      var from = starts[t.line] + t.character;
      var to = Math.min(text.length, from + t.length);
      if (to > from) marks.push([from, to, t.kind]);
    });
    marks.sort(function (a, b) { return a[0] - b[0]; });
    var html = "", pos = 0;
    marks.forEach(function (m) {
      if (m[0] < pos) return; // skip overlaps
      html += escapeHtml(text.slice(pos, m[0]));
      html += '<span class="cm-wt-' + m[2] + '">' + escapeHtml(text.slice(m[0], m[1])) + "</span>";
      pos = m[1];
    });
    return html + escapeHtml(text.slice(pos));
  }

  // The output language is whatever the current conversion produces.
  function outputLanguageIsWat() {
    return !currentSourceIsWat() && els.mode.value !== "wax";
  }

  function showOutput(text) {
    var lang = outputLanguageIsWat() ? "wat" : "wax";
    // Prefer the editor bundle's highlighter, so the output is coloured exactly
    // like the source pane (keywords/types/literals/comments + semantic tokens).
    if (globalThis.WaxCM && globalThis.WaxCM.highlightToHtml) {
      try {
        els.output.innerHTML = globalThis.WaxCM.highlightToHtml(text, lang, wax, waxKeywords);
        return;
      } catch (e) {
        /* fall through to the semantic-only path */
      }
    }
    try {
      var toks = lang === "wat" ? wax.semanticTokensWat(text) : wax.semanticTokens(text);
      els.output.innerHTML = highlightToHtml(text, toks || []);
    } catch (e) {
      els.output.textContent = text;
    }
  }

  // ---- Diagnostics list (both editor backends). CodeMirror also shows inline
  // squiggles, a lint gutter, and hover messages; this list adds a persistent,
  // click-to-jump view with related spans, and drives the status summary.

  function renderDiagnostics(diags) {
    els.diagnostics.textContent = "";
    diags.forEach(function (d) {
      var li = document.createElement("li");
      li.className = "wp-d-" + d.severity;
      var loc = document.createElement("span");
      loc.className = "wp-d-loc";
      loc.textContent = (d.startLine + 1) + ":" + (d.startChar + 1);
      li.appendChild(loc);
      var msg = document.createElement("span");
      msg.textContent = d.message + (d.warning ? " [" + d.warning + "]" : "");
      li.appendChild(msg);
      if (d.hint) {
        var hint = document.createElement("span");
        hint.className = "wp-d-hint";
        hint.textContent = "hint: " + d.hint;
        li.appendChild(hint);
      }
      (d.related || []).forEach(function (r) {
        var rel = document.createElement("span");
        rel.className = "wp-d-related";
        rel.textContent = (r.startLine + 1) + ":" + (r.startChar + 1) + " " + r.message;
        li.appendChild(rel);
      });
      li.addEventListener("click", function () {
        if (editor) editor.selectRange(d.startLine, d.startChar, d.endLine, d.endChar);
      });
      els.diagnostics.appendChild(li);
    });
  }

  function updateStatus(diags) {
    var errors = diags.filter(function (d) { return d.severity === "error"; }).length;
    var warns = diags.filter(function (d) { return d.severity === "warning"; }).length;
    var parts = [];
    if (errors) parts.push(errors + (errors === 1 ? " error" : " errors"));
    if (warns) parts.push(warns + (warns === 1 ? " warning" : " warnings"));
    setStatus(parts.length ? parts.join(", ") : "No problems.", errors > 0);
  }

  // Diagnostics arrive from CodeMirror's linter (or, in the fallback, from
  // run()); either way they are the raw wax `check` results.
  function onDiagnostics(diags) {
    renderDiagnostics(diags);
    updateStatus(diags);
  }

  function setStatus(msg, isError) {
    els.status.textContent = msg;
    els.status.classList.toggle("wp-status-error", !!isError);
  }

  // ---- The editor backend: CodeMirror when the bundle loaded, else a plain
  // textarea. Both expose the same tiny interface used below.

  // mdbook puts the active theme's name on <html> (light, rust, coal, navy,
  // ayu); coal/navy/ayu are the dark ones.
  function isDarkTheme() {
    return /(?:^|\s)(coal|navy|ayu)(?:\s|$)/.test(document.documentElement.className);
  }

  function buildEditor(doc) {
    if (editor) editor.destroy();
    els.host.textContent = "";
    var language = currentSourceIsWat() ? "wat" : "wax";

    if (globalThis.WaxCM && wax) {
      var cm = globalThis.WaxCM.createWaxEditor({
        parent: els.host,
        doc: doc,
        language: language,
        wax: wax,
        dark: isDarkTheme(),
        keywords: waxKeywords,
        onDocChange: scheduleRun,
        onDiagnostics: onDiagnostics,
      });
      editor = {
        isCM: true,
        getDoc: cm.getDoc,
        setDoc: cm.setDoc,
        focus: cm.focus,
        selectRange: cm.selectRange,
        destroy: cm.destroy,
      };
    } else {
      var ta = document.createElement("textarea");
      ta.className = "wp-input";
      ta.spellcheck = false;
      ta.setAttribute("autocapitalize", "off");
      ta.setAttribute("autocomplete", "off");
      ta.setAttribute("autocorrect", "off");
      ta.value = doc;
      ta.addEventListener("input", scheduleRun);
      els.host.appendChild(ta);
      editor = {
        isCM: false,
        getDoc: function () { return ta.value; },
        setDoc: function (t) { ta.value = t; },
        focus: function () { ta.focus(); },
        selectRange: function (sl, sc, el2, ec) {
          var s = offsetOf(ta.value, sl, sc);
          var e = offsetOf(ta.value, el2, ec);
          ta.focus();
          ta.setSelectionRange(s, Math.max(s, e));
        },
        destroy: function () { ta.remove(); },
      };
    }
  }

  // ---- The live conversion pass (output pane). Diagnostics are handled by the
  // CodeMirror linter; the textarea fallback computes them here instead.

  function run() {
    if (!wax || !editor) return;
    var src = editor.getDoc();
    var srcIsWat = currentSourceIsWat();

    var result;
    if (srcIsWat) result = wax.toWax(src);
    else if (els.mode.value === "wax") result = wax.format(src);
    else result = wax.toWat(src);

    // On a conversion error the output is left blank: the diagnostics (inline
    // squiggles and the list below) already report what is wrong, so echoing
    // the error text in the output pane is just noise.
    if (result.ok) showOutput(result.text || "");
    else els.output.textContent = "";

    if (!editor.isCM) {
      onDiagnostics(srcIsWat ? wax.checkWat(src) : wax.check(src, []));
    }
  }

  var debounceTimer = null;
  function scheduleRun() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(run, 150);
  }

  // ---- Pane labels track the direction / output mode.

  function updateLabels() {
    var srcIsWat = currentSourceIsWat();
    els.srcTitle.textContent = srcIsWat ? "WAT source" : "Wax source";
    els.modeField.style.display = srcIsWat ? "none" : "";
    if (srcIsWat) els.outTitle.textContent = "Wax output";
    else els.outTitle.textContent = els.mode.value === "wax" ? "Wax (formatted) output" : "WAT output";
  }

  // ---- Wiring.

  function wire() {
    // Switching direction changes the source language, so the editor is rebuilt
    // (its analysis is wired per language) around the current text.
    els.direction.addEventListener("change", function () {
      var doc = editor ? editor.getDoc() : DEFAULT_SRC;
      updateLabels();
      buildEditor(doc);
      run();
    });
    els.mode.addEventListener("change", function () {
      updateLabels();
      run();
    });

    els.example.addEventListener("change", function () {
      var code = els.example.value;
      if (!code) return;
      var wasWat = currentSourceIsWat();
      els.direction.value = "wax";
      updateLabels();
      if (wasWat) buildEditor(code); // language changed: rebuild
      else editor.setDoc(code);
      run();
    });

    els.format.addEventListener("click", function () {
      if (!wax || !editor) return;
      var src = editor.getDoc();
      var result = currentSourceIsWat() ? wax.formatWat(src) : wax.format(src);
      if (result.ok && result.text != null) {
        editor.setDoc(result.text);
        run();
      } else {
        setStatus(result.error || "cannot format invalid source", true);
      }
    });

    els.share.addEventListener("click", async function () {
      if (!editor) return;
      try {
        var encoded = await deflate(editor.getDoc());
        var hash = "#code=" + encoded + (currentSourceIsWat() ? "&dir=wat" : "");
        history.replaceState(null, "", location.pathname + location.search + hash);
        var link = location.href;
        if (navigator.clipboard && navigator.clipboard.writeText) {
          await navigator.clipboard.writeText(link);
          setStatus("Link copied — open it to reload this code.", false);
        } else {
          setStatus("Link ready in the address bar — copy it to share this code.", false);
        }
      } catch (e) {
        setStatus("Could not build a link: " + e.message, true);
      }
    });
  }

  async function populateExamples() {
    try {
      var examples = await (await fetch(ASSET_DIR + "examples.json")).json();
      examples.forEach(function (ex) {
        var opt = document.createElement("option");
        opt.value = ex.code;
        opt.textContent = ex.title;
        els.example.appendChild(opt);
      });
    } catch (e) {
      /* Examples are a convenience; a missing file must not break the page. */
    }
  }

  async function loadKeywords() {
    try {
      var kws = await (await fetch(ASSET_DIR + "keywords.json")).json();
      if (Array.isArray(kws)) waxKeywords = kws;
    } catch (e) {
      /* Keyword colouring is a nicety; a missing file just leaves them plain. */
    }
  }

  async function boot() {
    wire();
    populateExamples();
    await loadKeywords();

    // Restore a shared snippet, else the default.
    var initial = DEFAULT_SRC;
    var frag = readFragment();
    if (frag.code) {
      try {
        initial = await inflate(frag.code);
        if (frag.dir === "wat") els.direction.value = "wat";
      } catch (e) {
        initial = DEFAULT_SRC;
      }
    }
    updateLabels();

    try {
      wax = await loadWax();
    } catch (e) {
      root.classList.add("wp-unsupported");
      setStatus(root.getAttribute("data-unsupported") + " (" + e.message + ")", true);
      return;
    }

    await loadEditorBundle(); // best-effort; falls back to a textarea
    buildEditor(initial);
    run();

    // mdbook switches theme in place (no reload); rebuild the editor when its
    // light/dark-ness flips so the CodeMirror colours follow.
    var lastDark = isDarkTheme();
    new MutationObserver(function () {
      var d = isDarkTheme();
      if (d !== lastDark && editor && editor.isCM) {
        lastDark = d;
        buildEditor(editor.getDoc());
        run();
      }
    }).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
  }

  boot();
})();
</script>
