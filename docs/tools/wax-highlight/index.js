#!/usr/bin/env node
// mdbook preprocessor: syntax-highlight ```wax code blocks using the same
// TextMate grammar the VS Code extension ships (editors/vscode/syntaxes).
//
// It tokenizes each block with vscode-textmate + vscode-oniguruma and emits a
// <pre class="hljs wax-highlight"> whose spans carry mdbook's own hljs-* CSS
// classes, so the result adopts whatever site theme (light/coal/ayu/...) is
// active with no extra stylesheet. It deliberately emits no inner <code>
// element: mdbook's book.js runs highlight.js over every <pre><code>, which
// would otherwise re-tokenize our text and destroy the spans.

'use strict';

const fs = require('fs');
const path = require('path');
const vsctm = require('vscode-textmate');
const oniguruma = require('vscode-oniguruma');

const SCOPE = 'source.wax';

// --- protocol: `supports <renderer>` probe, else JSON on stdin -------------

if (process.argv[2] === 'supports') {
  // We only produce HTML. Exit 0 = supported, 1 = not.
  process.exit(process.argv[3] === 'html' ? 0 : 1);
}

// --- scope -> mdbook hljs-* class ------------------------------------------
// Ordered longest-prefix-first. The first entry whose key is a prefix of the
// token's most-specific scope wins. Only classes present in BOTH mdbook's
// light highlight.css and ayu-highlight.css are used (e.g. hljs-title, not
// hljs-built_in which ayu spells differently).
const SCOPE_CLASS = [
  ['comment', 'hljs-comment'],
  ['string', 'hljs-string'],
  ['constant.character.escape', 'hljs-string'],
  ['constant.numeric', 'hljs-number'],
  ['constant.language', 'hljs-literal'],
  ['entity.name.function', 'hljs-title'],
  ['entity.name.type', 'hljs-type'],
  ['entity.name.label', 'hljs-symbol'],
  ['entity.other.attribute-name', 'hljs-meta'],
  ['meta.attribute', 'hljs-meta'],
  ['punctuation.definition.attribute', 'hljs-meta'],
  ['keyword.control.attribute', 'hljs-meta'],
  ['keyword.operator.word', 'hljs-keyword'],
  ['keyword.control', 'hljs-keyword'],
  ['storage', 'hljs-keyword'],
  ['support.type', 'hljs-type'],
  ['support.function', 'hljs-title'],
  ['variable.other.property', 'hljs-variable'],
  ['invalid', 'hljs-deletion'],
];

function classFor(scopes) {
  // scopes: outermost..innermost; try the most specific first.
  for (let i = scopes.length - 1; i >= 0; i--) {
    const s = scopes[i];
    for (const [prefix, cls] of SCOPE_CLASS) {
      if (s === prefix || s.startsWith(prefix + '.')) return cls;
    }
  }
  return null; // punctuation, plain operators -> default text colour
}

function escapeHtml(s) {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

// --- grammar registry ------------------------------------------------------

function makeRegistry(grammarPath) {
  const wasmBin = fs.readFileSync(
    require.resolve('vscode-oniguruma/release/onig.wasm')
  ).buffer;
  const onigLib = oniguruma.loadWASM(wasmBin).then(() => ({
    createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
    createOnigString: (s) => new oniguruma.OnigString(s),
  }));
  return new vsctm.Registry({
    onigLib,
    loadGrammar: async (scopeName) => {
      if (scopeName !== SCOPE) return null;
      const data = fs.readFileSync(grammarPath, 'utf8');
      return vsctm.parseRawGrammar(data, grammarPath);
    },
  });
}

function highlight(grammar, code) {
  // Strip one trailing newline so we don't render a blank final line.
  const src = code.endsWith('\n') ? code.slice(0, -1) : code;
  const lines = src.split('\n');
  let ruleStack = vsctm.INITIAL;
  const out = [];
  for (const line of lines) {
    const r = grammar.tokenizeLine(line, ruleStack);
    let html = '';
    let runCls = null; // class of the current run, coalescing adjacent tokens
    let runText = '';
    const flush = () => {
      if (runText === '') return;
      html += runCls
        ? `<span class="${runCls}">${runText}</span>`
        : runText;
      runText = '';
    };
    for (const t of r.tokens) {
      const text = escapeHtml(line.substring(t.startIndex, t.endIndex));
      const cls = classFor(t.scopes);
      if (cls !== runCls) {
        flush();
        runCls = cls;
      }
      runText += text;
    }
    flush();
    out.push(html);
    ruleStack = r.ruleStack;
  }
  // Mirror mdbook's own structure: the inner element carries the theme
  // background and the horizontal scroll, while the outer <pre> stays a bare,
  // non-clipping container for the copy button and its tooltip. (If the <pre>
  // itself scrolled, overflow-x:auto would force overflow-y:auto and clip the
  // tooltip.) The inner element must NOT be a <code>, or mdbook's highlight.js
  // would re-tokenize it and wipe our spans.
  return `<pre class="wax-highlight"><span class="hljs wax-code">${out.join(
    '\n'
  )}</span></pre>`;
}

// --- fenced-code scanner ---------------------------------------------------
// Replaces top-level ```wax (and ~~~wax, and info strings like `wax,check`)
// blocks. Leaves every other fence untouched for mdbook's own highlighter.

const FENCE_OPEN = /^(\s*)(`{3,}|~{3,})\s*([^\n]*)$/;

function transformContent(content, grammar) {
  const lines = content.split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = FENCE_OPEN.exec(lines[i]);
    if (!m) {
      out.push(lines[i]);
      continue;
    }
    const [, indent, fence] = m;
    const info = m[3].trim();
    const lang = info.split(/[\s,]/)[0].toLowerCase();
    const fenceChar = fence[0];
    const closeRe = new RegExp(
      `^\\s*${fenceChar === '`' ? '`' : '~'}{${fence.length},}\\s*$`
    );
    // Collect body up to the matching close fence (or EOF).
    const body = [];
    let j = i + 1;
    for (; j < lines.length; j++) {
      if (closeRe.test(lines[j])) break;
      body.push(lines[j]);
    }
    const closed = j < lines.length;
    if (lang === 'wax' && closed) {
      // Blank lines around the raw HTML so pulldown-cmark treats it as an
      // HTML block rather than folding it into a paragraph.
      out.push('');
      out.push(highlight(grammar, body.join('\n') + '\n'));
      out.push('');
    } else {
      out.push(lines[i]);
      for (const b of body) out.push(b);
      if (closed) out.push(lines[j]);
    }
    i = closed ? j : lines.length;
  }
  return out.join('\n');
}

function walk(section, grammar) {
  if (section && section.Chapter) {
    const ch = section.Chapter;
    if (typeof ch.content === 'string') {
      ch.content = transformContent(ch.content, grammar);
    }
    if (Array.isArray(ch.sub_items)) {
      ch.sub_items.forEach((s) => walk(s, grammar));
    }
  }
}

// --- main ------------------------------------------------------------------

async function main() {
  const input = fs.readFileSync(0, 'utf8');
  const [context, book] = JSON.parse(input);
  const grammarPath = path.resolve(
    context.root,
    '..',
    'editors/vscode/syntaxes/wax.tmLanguage.json'
  );
  const registry = makeRegistry(grammarPath);
  const grammar = await registry.loadGrammar(SCOPE);
  if (!grammar) throw new Error(`could not load grammar ${SCOPE}`);
  book.items.forEach((s) => walk(s, grammar));
  process.stdout.write(JSON.stringify(book));
}

main().catch((e) => {
  process.stderr.write(`mdbook-wax-highlight: ${e.stack || e}\n`);
  process.exit(1);
});
