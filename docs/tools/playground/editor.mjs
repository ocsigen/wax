// CodeMirror 6 editor for the Wax docs playground (PLAYGROUND.md phase 2).
//
// esbuild bundles this into wax-editor.bundle.js as an IIFE that installs
// `globalThis.WaxCM` (see package.json "build"). The page calls
// `WaxCM.createWaxEditor(...)`, passing the `globalThis.wax` analysis object the
// wasm bundle installs. Every language feature is driven by that object — the
// same exports the VS Code extension and the LSP server use — so highlighting,
// diagnostics, completion, etc. are one source of truth with the toolchain
// rather than a re-implemented grammar.
//
// Positions: wax uses zero-based (line, character) in UTF-16 code units, which
// is exactly CodeMirror's native offset model, so the mapping is arithmetic.

import { EditorState, StateField } from "@codemirror/state";
import {
  EditorView,
  Decoration,
  WidgetType,
  ViewPlugin,
  hoverTooltip,
  showTooltip,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  drawSelection,
} from "@codemirror/view";
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from "@codemirror/commands";
import {
  autocompletion,
  completionKeymap,
} from "@codemirror/autocomplete";
import { linter, lintGutter, lintKeymap } from "@codemirror/lint";
import {
  foldGutter,
  codeFolding,
  foldService,
  foldKeymap,
} from "@codemirror/language";

// ---- position mapping -------------------------------------------------------

function posToLC(state, pos) {
  const line = state.doc.lineAt(pos);
  return { line: line.number - 1, ch: pos - line.from };
}

function lcToPos(state, line, ch) {
  if (line < 0) return 0;
  if (line >= state.doc.lines) return state.doc.length;
  const l = state.doc.line(line + 1);
  return Math.min(l.from + Math.max(0, ch), l.to);
}

function rangeToPos(state, r) {
  const from = lcToPos(state, r.startLine, r.startChar);
  const to = lcToPos(state, r.endLine, r.endChar);
  return { from, to: Math.max(from, to) };
}

// ---- the analysis provider (dispatches Wax vs WAT exports) ------------------

// A one-entry memo so features that recompute over the whole document (tokens,
// folds, inlays) don't re-enter the wasm on every viewport tick.
function memo1(fn) {
  let key = null;
  let val = null;
  return (src) => {
    if (src !== key) {
      key = src;
      val = fn(src);
    }
    return val;
  };
}

function safe(fn, fallback) {
  try {
    const v = fn();
    return v == null ? fallback : v;
  } catch (_e) {
    return fallback;
  }
}

function buildProvider(wax, language) {
  const wat = language === "wat";
  return {
    check: (src) => safe(() => (wat ? wax.checkWat(src) : wax.check(src, [])), []),
    semanticTokens: memo1((src) =>
      safe(() => (wat ? wax.semanticTokensWat(src) : wax.semanticTokens(src)), [])
    ),
    folding: memo1((src) =>
      safe(() => (wat ? wax.foldingRangesWat(src) : wax.foldingRanges(src)), [])
    ),
    inlays: memo1((src) =>
      safe(() => (wat ? wax.inlaysWat(src) : wax.inlays(src)), [])
    ),
    hover: (src, l, c) =>
      safe(() => (wat ? wax.hoverWat(src, l, c) : wax.hover(src, l, c)), null),
    completion: (src, l, c) =>
      safe(() => (wat ? wax.completionWat(src, l, c, []) : wax.completion(src, l, c, [])), []),
    signatureHelp: (src, l, c) =>
      safe(() => (wat ? wax.signatureHelpWat(src, l, c) : wax.signatureHelp(src, l, c)), null),
    references: (src, l, c) =>
      safe(() => (wat ? wax.referencesWat(src, l, c) : wax.references(src, l, c)), []),
  };
}

// ---- syntax highlighting ----------------------------------------------------
//
// Two sources are merged: the toolchain's semantic tokens, which classify
// identifiers (wax.semanticTokens), and a small hand lexer below for everything
// else — keywords, primitive types, numbers, strings, comments. The semantic
// classification always wins where the two overlap, so a local variable named
// like a type (e.g. `i64`) is coloured as a variable, not the type: any lexer
// span overlapping a semantic span is dropped.
//
// The keyword set is not hardcoded: it is extracted from lib-wax/lexer.ml at
// build time (docs/gen_keywords.ml) and passed in, so it cannot drift from the
// compiler.

function semanticOffsets(text, tokens) {
  const starts = lineStarts(text);
  const out = [];
  for (const t of tokens || []) {
    if (t.line >= starts.length) continue;
    const from = starts[t.line] + t.character;
    const to = Math.min(text.length, from + t.length);
    if (to > from) out.push([from, to, t.kind]);
  }
  return out;
}

// Merge lexer spans with semantic spans, dropping any lexer span that overlaps a
// semantic one (semantic wins). Inputs and output are [from, to, kind]; the
// result is sorted and pairwise-disjoint.
function mergeSpans(lex, sem) {
  const s = sem.slice().sort((a, b) => a[0] - b[0]);
  const overlaps = (from, to) => {
    for (const [sf, st] of s) {
      if (sf >= to) break; // sorted: no later span can overlap either
      if (st > from) return true;
    }
    return false;
  };
  const kept = lex.filter(([from, to]) => !overlaps(from, to));
  return kept.concat(s).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
}

function buildHighlight(text, language, semTokens, keywords) {
  const lex = language === "wat" ? lexWat(text) : lexWax(text, keywords);
  return mergeSpans(lex, semanticOffsets(text, semTokens));
}

function highlightPlugin(language, provider, keywords) {
  const build = (state) => {
    const text = state.doc.toString();
    const spans = buildHighlight(text, language, provider.semanticTokens(text), keywords);
    return Decoration.set(
      spans.map(([from, to, kind]) =>
        Decoration.mark({ class: "cm-wt-" + kind }).range(from, to)
      )
    );
  };
  return ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = build(view.state);
      }
      update(u) {
        if (u.docChanged) this.decorations = build(u.view.state);
      }
    },
    { decorations: (v) => v.decorations }
  );
}

// ---- the hand lexer (keywords, types, literals, comments) -------------------

// Numeric value types — the fixed WebAssembly value types, never used as
// identifiers, so safe to colour lexically. Abstract/named types come through
// the semantic layer instead.
const WAX_TYPES = new Set("i8 i16 i32 i64 f32 f64 v128".split(" "));

const isWord = (c) => c !== undefined && /[A-Za-z0-9_]/.test(c);

// Each lexer returns [from, to, kind] spans, kind being a cm-wt-* suffix.
// [keywords] is a Set of the language's keyword strings.
function lexWax(text, keywords) {
  const out = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      let j = i + 2;
      while (j < n && text[j] !== "\n") j++;
      out.push([i, j, "comment"]);
      i = j;
    } else if (c === "/" && text[i + 1] === "*") {
      let j = i + 2;
      while (j < n && !(text[j] === "*" && text[j + 1] === "/")) j++;
      j = Math.min(n, j + 2);
      out.push([i, j, "comment"]);
      i = j;
    } else if (c === '"') {
      let j = i + 1;
      while (j < n && text[j] !== '"' && text[j] !== "\n") {
        if (text[j] === "\\") j++;
        j++;
      }
      j = Math.min(n, j + 1);
      out.push([i, j, "string"]);
      i = j;
    } else if (c === "'") {
      // A char literal is one code point (or an escape) between quotes; a label
      // is a bare `'name` with no closing quote.
      let end = -1;
      if (text[i + 1] === "\\") {
        let j = i + 2;
        while (j < n && text[j] !== "'" && text[j] !== "\n") j++;
        if (text[j] === "'") end = j + 1;
      } else {
        const hi = text.charCodeAt(i + 1);
        const after = hi >= 0xd800 && hi <= 0xdbff ? i + 3 : i + 2;
        if (text[after] === "'") end = after + 1;
      }
      if (end >= 0) {
        out.push([i, end, "string"]);
        i = end;
      } else {
        let k = i + 1;
        while (k < n && isWord(text[k])) k++; // a label: left uncoloured
        i = Math.max(k, i + 1);
      }
    } else if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(text[i + 1] || ""))) {
      let j = i + 1;
      while (j < n && /[0-9a-fA-FxXoObB._]/.test(text[j])) j++;
      out.push([i, j, "number"]);
      i = j;
    } else if (/[A-Za-z_]/.test(c)) {
      let j = i + 1;
      while (j < n && isWord(text[j])) j++;
      const w = text.slice(i, j);
      if (keywords.has(w)) out.push([i, j, "keyword"]);
      else if (WAX_TYPES.has(w)) out.push([i, j, "type"]);
      // else an identifier: left to the semantic layer.
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

// WAT is keyword-heavy: every bare word (not `$name`, not a number/string) is a
// keyword, type or instruction, so colour them all; `$` names go to the
// semantic layer. Comments are `;; …` and nesting `(; … ;)`.
function lexWat(text) {
  const out = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const c = text[i];
    if (c === ";" && text[i + 1] === ";") {
      let j = i + 2;
      while (j < n && text[j] !== "\n") j++;
      out.push([i, j, "comment"]);
      i = j;
    } else if (c === "(" && text[i + 1] === ";") {
      let j = i + 2;
      let depth = 1;
      while (j < n && depth > 0) {
        if (text[j] === "(" && text[j + 1] === ";") {
          depth++;
          j += 2;
        } else if (text[j] === ";" && text[j + 1] === ")") {
          depth--;
          j += 2;
        } else j++;
      }
      out.push([i, j, "comment"]);
      i = j;
    } else if (c === '"') {
      let j = i + 1;
      while (j < n && text[j] !== '"' && text[j] !== "\n") {
        if (text[j] === "\\") j++;
        j++;
      }
      j = Math.min(n, j + 1);
      out.push([i, j, "string"]);
      i = j;
    } else if (c === "$") {
      let j = i + 1;
      while (j < n && !/[\s()";]/.test(text[j])) j++;
      i = j; // a name: left to the semantic layer
    } else if (/[0-9]/.test(c) || ((c === "+" || c === "-" || c === ".") && /[0-9]/.test(text[i + 1] || ""))) {
      let j = i + 1;
      while (j < n && /[0-9a-fA-FxX._+\-pP]/.test(text[j])) j++;
      out.push([i, j, "number"]);
      i = j;
    } else if (/[A-Za-z_]/.test(c)) {
      let j = i + 1;
      while (j < n && !/[\s()";]/.test(text[j])) j++;
      out.push([i, j, "keyword"]);
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

function lineStarts(text) {
  const starts = [0];
  for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) starts.push(i + 1);
  return starts;
}

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Static highlighting for the read-only output pane: the same merged lexer +
// semantic spans as the editor, rendered to HTML with the same cm-wt-* classes
// so both panes look identical. Exported for the page.
export function highlightToHtml(text, language, wax, keywords) {
  const wat = language === "wat";
  const kw = keywords instanceof Set ? keywords : new Set(keywords || []);
  let sem = [];
  try {
    sem = (wat ? wax.semanticTokensWat(text) : wax.semanticTokens(text)) || [];
  } catch (_e) {
    sem = [];
  }
  const spans = buildHighlight(text, language, sem, kw); // sorted, disjoint
  let html = "";
  let pos = 0;
  for (const [from, to, kind] of spans) {
    html += escapeHtml(text.slice(pos, from));
    html += '<span class="cm-wt-' + kind + '">' + escapeHtml(text.slice(from, to)) + "</span>";
    pos = to;
  }
  return html + escapeHtml(text.slice(pos));
}

function lexPlugin(language, keywords) {
  return ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = buildLex(view.state, language, keywords);
      }
      update(u) {
        if (u.docChanged) this.decorations = buildLex(u.view.state, language, keywords);
      }
    },
    { decorations: (v) => v.decorations }
  );
}

// ---- inlay hints (inferred let types) ---------------------------------------

class InlayWidget extends WidgetType {
  constructor(label) {
    super();
    this.label = label;
  }
  eq(other) {
    return other.label === this.label;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-wt-inlay";
    span.textContent = this.label;
    return span;
  }
  ignoreEvent() {
    return true;
  }
}

function buildInlays(state, provider) {
  const hints = provider.inlays(state.doc.toString());
  const ranges = [];
  for (const h of hints) {
    const pos = lcToPos(state, h.line, h.char);
    ranges.push(Decoration.widget({ widget: new InlayWidget(h.label), side: 1 }).range(pos));
  }
  ranges.sort((a, b) => a.from - b.from);
  return Decoration.set(ranges);
}

function inlayPlugin(provider) {
  return ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = buildInlays(view.state, provider);
      }
      update(u) {
        if (u.docChanged) this.decorations = buildInlays(u.view.state, provider);
      }
    },
    { decorations: (v) => v.decorations }
  );
}

// ---- document highlight (occurrences of the symbol under the cursor) --------

const refMark = Decoration.mark({ class: "cm-wt-refhl" });

function buildRefs(state, provider) {
  const pos = state.selection.main.head;
  const { line, ch } = posToLC(state, pos);
  const refs = provider.references(state.doc.toString(), line, ch);
  if (refs.length < 2) return Decoration.none; // a lone occurrence is just the cursor's own token
  const ranges = [];
  for (const r of refs) {
    const { from, to } = rangeToPos(state, r);
    if (to > from) ranges.push(refMark.range(from, to));
  }
  ranges.sort((a, b) => a.from - b.from);
  return Decoration.set(ranges);
}

function refHighlightPlugin(provider) {
  return ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = buildRefs(view.state, provider);
      }
      update(u) {
        if (u.docChanged || u.selectionSet)
          this.decorations = buildRefs(u.view.state, provider);
      }
    },
    { decorations: (v) => v.decorations }
  );
}

// ---- diagnostics + quick fixes ----------------------------------------------

function severityOf(d) {
  if (d.severity === "error") return "error";
  if (d.severity === "warning") return "warning";
  return "hint"; // suggestion
}

function makeLinter(provider, onDiagnostics) {
  return linter(
    (view) => {
      const diags = provider.check(view.state.doc.toString());
      if (onDiagnostics) onDiagnostics(diags);
      return diags.map((d) => {
        const { from, to } = rangeToPos(view.state, d);
        const cm = {
          from,
          to: to > from ? to : from + 1,
          severity: severityOf(d),
          message: d.message + (d.warning ? " [" + d.warning + "]" : ""),
        };
        if (d.hint) cm.message += "\n" + d.hint;
        if (d.edit) {
          const e = d.edit;
          cm.actions = [
            {
              name: "Fix",
              apply(v) {
                const { from: ef, to: et } = rangeToPos(v.state, e);
                v.dispatch({ changes: { from: ef, to: et, insert: e.newText } });
              },
            },
          ];
        }
        return cm;
      });
    },
    { delay: 200 }
  );
}

// ---- hover ------------------------------------------------------------------

function makeHover(provider) {
  return hoverTooltip((view, pos) => {
    const { line, ch } = posToLC(view.state, pos);
    const h = provider.hover(view.state.doc.toString(), line, ch);
    if (!h) return null;
    const { from, to } = rangeToPos(view.state, h);
    return {
      pos: from,
      end: to > from ? to : pos,
      create() {
        const dom = document.createElement("div");
        dom.className = "cm-wt-hover";
        dom.textContent = h.type;
        return { dom };
      },
    };
  });
}

// ---- completion -------------------------------------------------------------

function cmKind(kind) {
  switch (kind) {
    case "function":
    case "method":
      return "function";
    case "type":
    case "array":
      return "type";
    case "namespace":
      return "namespace";
    case "keyword":
      return "keyword";
    case "field":
    case "property":
      return "property";
    default:
      return "variable";
  }
}

function makeCompletion(provider) {
  return autocompletion({
    override: [
      (context) => {
        const word = context.matchBefore(/[\w$']+/);
        if (!word && !context.explicit) return null;
        const { line, ch } = posToLC(context.state, context.pos);
        const items = provider.completion(context.state.doc.toString(), line, ch);
        if (!items.length) return null;
        return {
          from: word ? word.from : context.pos,
          options: items.map((it) => ({
            label: it.name,
            type: cmKind(it.kind),
            detail: it.detail || undefined,
          })),
          validFor: /^[\w$']*$/,
        };
      },
    ],
  });
}

// ---- signature help (shown as a tooltip while the cursor is inside a call) --

function sigTooltip(state, provider) {
  const pos = state.selection.main.head;
  const { line, ch } = posToLC(state, pos);
  const sig = provider.signatureHelp(state.doc.toString(), line, ch);
  if (!sig) return null;
  return {
    pos,
    create() {
      const dom = document.createElement("div");
      dom.className = "cm-wt-sig";
      const active = sig.parameters && sig.parameters[sig.active];
      if (active) {
        dom.appendChild(document.createTextNode(sig.label.slice(0, active.startOff)));
        const b = document.createElement("span");
        b.className = "cm-wt-sig-active";
        b.textContent = sig.label.slice(active.startOff, active.endOff);
        dom.appendChild(b);
        dom.appendChild(document.createTextNode(sig.label.slice(active.endOff)));
      } else {
        dom.textContent = sig.label;
      }
      return { dom };
    },
  };
}

function sigHelpField(provider) {
  return StateField.define({
    create: (state) => sigTooltip(state, provider),
    update: (val, tr) =>
      tr.docChanged || tr.selection ? sigTooltip(tr.state, provider) : val,
    provide: (f) => showTooltip.from(f),
  });
}

// ---- folding ----------------------------------------------------------------

function makeFoldService(provider) {
  return foldService.of((state, lineStart) => {
    const lineNo = state.doc.lineAt(lineStart).number - 1;
    const ranges = provider.folding(state.doc.toString());
    for (const r of ranges) {
      if (r.startLine === lineNo && r.endLine > r.startLine) {
        const from = state.doc.line(r.startLine + 1).to;
        const endLine = Math.min(r.endLine + 1, state.doc.lines);
        const to = state.doc.line(endLine).to;
        if (to > from) return { from, to };
      }
    }
    return null;
  });
}

// ---- editor theme (transparent, inheriting the site's fonts/colors) ---------
//
// These rules are part of an EditorView.theme, which outranks CodeMirror's
// generic base theme (injected at runtime, so it would otherwise win over page
// CSS). Colours come from mdbook's own CSS variables, so tooltips, the caret and
// the selection match whichever site theme the reader picked. `dark` steers the
// base theme's remaining defaults.

function waxTheme(dark) {
  return EditorView.theme(
    {
      "&": {
        backgroundColor: "transparent",
        color: "inherit",
        height: "100%",
        fontSize: "var(--code-font-size, 0.875em)",
      },
      ".cm-scroller": {
        fontFamily: "var(--mono-font, monospace)",
        lineHeight: "1.5",
        overflow: "auto",
      },
      "&.cm-focused": { outline: "none" },
      ".cm-gutters": {
        backgroundColor: "transparent",
        color: "inherit",
        border: "none",
        opacity: "0.45",
      },
      ".cm-activeLine": { backgroundColor: "rgba(128,128,128,0.08)" },
      ".cm-activeLineGutter": { backgroundColor: "transparent" },
      // drawSelection() replaces the native caret and selection; give both a
      // colour that reads on light and dark site themes alike.
      ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--fg, currentColor)" },
      "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection":
        { backgroundColor: "rgba(110,140,220,0.35)" },
      // Tooltips (hover, signature help, completion) match mdbook's popups.
      ".cm-tooltip": {
        backgroundColor: "var(--theme-popup-bg, var(--bg, #fff))",
        border: "1px solid var(--theme-popup-border, rgba(128,128,128,0.4))",
        color: "var(--fg, inherit)",
        borderRadius: "4px",
      },
      ".cm-tooltip.cm-tooltip-cursor": { padding: "0.25em 0.4em" },
      ".cm-tooltip-hover .cm-tooltip-section": { padding: "0.25em 0.4em" },
      ".cm-tooltip-autocomplete": { padding: "0" },
      ".cm-tooltip-autocomplete > ul": { fontFamily: "var(--mono-font, monospace)" },
      ".cm-tooltip-autocomplete > ul > li[aria-selected]": {
        backgroundColor: "var(--theme-hover, rgba(110,140,220,0.35))",
        color: "var(--fg, inherit)",
      },
    },
    { dark: !!dark }
  );
}

// ---- public API -------------------------------------------------------------

export function createWaxEditor(opts) {
  const { parent, doc, language, wax, onDocChange, onDiagnostics, dark } = opts;
  const provider = buildProvider(wax, language);
  const keywords = new Set(opts.keywords || []);

  const changeListener = EditorView.updateListener.of((u) => {
    if (u.docChanged && onDocChange) onDocChange(u.state.doc.toString());
  });

  const extensions = [
    lineNumbers(),
    highlightActiveLineGutter(),
    highlightActiveLine(),
    history(),
    drawSelection(),
    codeFolding(),
    foldGutter(),
    makeFoldService(provider),
    highlightPlugin(language, provider, keywords),
    inlayPlugin(provider),
    refHighlightPlugin(provider),
    makeLinter(provider, onDiagnostics),
    lintGutter(),
    makeHover(provider),
    makeCompletion(provider),
    sigHelpField(provider),
    changeListener,
    keymap.of([
      indentWithTab,
      ...defaultKeymap,
      ...historyKeymap,
      ...completionKeymap,
      ...lintKeymap,
      ...foldKeymap,
    ]),
    waxTheme(dark),
    EditorState.tabSize.of(4),
  ];

  const view = new EditorView({
    doc: doc || "",
    parent,
    extensions,
  });

  // The mdbook host page has a document-level keydown handler that turns the
  // arrow keys into previous/next-chapter navigation (and single keys into
  // shortcuts). Its content is a contenteditable, not an <input>, so mdbook
  // does not exempt it; stop keydowns from bubbling out once CodeMirror (which
  // listens on the inner content DOM) has had them.
  view.dom.addEventListener("keydown", (e) => e.stopPropagation());

  return {
    view,
    getDoc: () => view.state.doc.toString(),
    setDoc(text) {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
      });
    },
    focus: () => view.focus(),
    getCursor: () => view.state.selection.main.head,
    setCursor(pos) {
      const p = Math.max(0, Math.min(pos, view.state.doc.length));
      view.dispatch({ selection: { anchor: p }, scrollIntoView: true });
    },
    selectRange(startLine, startChar, endLine, endChar) {
      const from = lcToPos(view.state, startLine, startChar);
      const to = lcToPos(view.state, endLine, endChar);
      view.dispatch({
        selection: { anchor: from, head: Math.max(from, to) },
        scrollIntoView: true,
      });
      view.focus();
    },
    destroy: () => view.destroy(),
  };
}
