// Shared activation: register a document formatter and publish diagnostics
// (syntax / type / lint) for both the Wax and the Wasm-text (WAT) languages, and
// a document outline for Wax. All are computed by the wasm-compiled toolchain
// in-process. Format-on-save needs no extra code — VS Code drives any registered
// formatter when `editor.formatOnSave` is on.

import * as vscode from "vscode";
import {
  loadWax,
  LoadOptions,
  Wax,
  WaxSymbol,
  WaxHover,
  WaxInlay,
  WaxRange,
  WaxEdit,
  WaxRenameResult,
  WaxCompletion,
  WaxSignature,
  WaxSemanticToken,
  WaxFolding,
  FormatResult,
  WaxDiagnostic,
} from "./wax-runtime";

// Legend for semantic highlighting; the bridge's token kinds are exactly these
// standard types, so a theme colours them without extra configuration.
const SEMANTIC_TYPES = [
  "namespace",
  "type",
  "function",
  "parameter",
  "variable",
  "property",
];
const SEMANTIC_LEGEND = new vscode.SemanticTokensLegend(SEMANTIC_TYPES, []);

// One entry per language this extension serves. Both dispatch into the same
// wasm module (see wax_format_js.ml); they differ only in which method they call
// (Wax type-checks, WAT validates).
interface LanguageSpec {
  id: string;
  format(wax: Wax, src: string): FormatResult;
  // Diagnostics, specialized to the active `wax.define` set (mirroring `-D`).
  // WAT ignores the defines (it has no Wax-side conditional dimming).
  check(wax: Wax, src: string, defines: string[]): WaxDiagnostic[];
  symbols(wax: Wax, src: string): WaxSymbol[];
  // Type of the expression at a position, for hover. Only Wax has a typed tree;
  // omitted for WAT (its validator builds none), so no hover is registered there.
  hover?(wax: Wax, src: string, line: number, character: number): WaxHover | null;
  // Inferred-type inlay hints. Wax only, for the same reason.
  inlays?(wax: Wax, src: string): WaxInlay[];
  // Definition span(s) at a position, for go-to-definition. Wax only.
  definition?(wax: Wax, src: string, line: number, character: number): WaxRange[];
  // Type-declaration span(s) of the value at a position, for
  // go-to-type-definition. Wax only.
  typeDefinition?(
    wax: Wax,
    src: string,
    line: number,
    character: number,
  ): WaxRange[];
  // Every occurrence of the symbol at a position, for find-references and
  // document highlight. Wax only.
  references?(wax: Wax, src: string, line: number, character: number): WaxRange[];
  // Rename support: the renameable symbol's span at a position, and the edits to
  // rename it. Wax only.
  renamePrepare?(
    wax: Wax,
    src: string,
    line: number,
    character: number,
  ): WaxRange | null;
  rename?(
    wax: Wax,
    src: string,
    line: number,
    character: number,
    newName: string,
  ): WaxRenameResult;
  // Names in scope at a position, for completion, specialized to the active
  // `wax.define` set (an empty array keeps the all-configurations behaviour).
  // Wax only.
  completion?(
    wax: Wax,
    src: string,
    line: number,
    character: number,
    defines: string[],
  ): WaxCompletion[];
  // The enclosing call's signature at a position, for signature help. Wax only.
  signatureHelp?(
    wax: Wax,
    src: string,
    line: number,
    character: number,
  ): WaxSignature | null;
  // Classified identifier occurrences, for semantic highlighting. Wax only.
  semanticTokens?(wax: Wax, src: string): WaxSemanticToken[];
  // Foldable regions (block bodies, block comments). Wax only.
  foldingRanges?(wax: Wax, src: string): WaxFolding[];
  // The chain of enclosing spans at a position, innermost first, for
  // expand/shrink selection. Wax only.
  selectionRange?(
    wax: Wax,
    src: string,
    line: number,
    character: number,
  ): WaxRange[];
}

const LANGUAGES: LanguageSpec[] = [
  {
    id: "wax",
    format: (wax, src) => wax.format(src),
    check: (wax, src, defines) => wax.check(src, defines),
    symbols: (wax, src) => wax.symbols(src),
    hover: (wax, src, line, character) => wax.hover(src, line, character),
    inlays: (wax, src) => wax.inlays(src),
    definition: (wax, src, line, character) =>
      wax.definition(src, line, character),
    typeDefinition: (wax, src, line, character) =>
      wax.typeDefinition(src, line, character),
    references: (wax, src, line, character) =>
      wax.references(src, line, character),
    renamePrepare: (wax, src, line, character) =>
      wax.renamePrepare(src, line, character),
    rename: (wax, src, line, character, newName) =>
      wax.rename(src, line, character, newName),
    completion: (wax, src, line, character, defines) =>
      wax.completion(src, line, character, defines),
    signatureHelp: (wax, src, line, character) =>
      wax.signatureHelp(src, line, character),
    semanticTokens: (wax, src) => wax.semanticTokens(src),
    foldingRanges: (wax, src) => wax.foldingRanges(src),
    selectionRange: (wax, src, line, character) =>
      wax.selectionRange(src, line, character),
  },
  {
    id: "wat",
    format: (wax, src) => wax.formatWat(src),
    check: (wax, src, _defines) => wax.checkWat(src),
    symbols: (wax, src) => wax.symbolsWat(src),
    hover: (wax, src, line, character) => wax.hoverWat(src, line, character),
    definition: (wax, src, line, character) =>
      wax.definitionWat(src, line, character),
    typeDefinition: (wax, src, line, character) =>
      wax.typeDefinitionWat(src, line, character),
    references: (wax, src, line, character) =>
      wax.referencesWat(src, line, character),
    renamePrepare: (wax, src, line, character) =>
      wax.renamePrepareWat(src, line, character),
    rename: (wax, src, line, character, newName) =>
      wax.renameWat(src, line, character, newName),
    foldingRanges: (wax, src) => wax.foldingRangesWat(src),
    selectionRange: (wax, src, line, character) =>
      wax.selectionRangeWat(src, line, character),
    semanticTokens: (wax, src) => wax.semanticTokensWat(src),
    signatureHelp: (wax, src, line, character) =>
      wax.signatureHelpWat(src, line, character),
    completion: (wax, src, line, character, defines) =>
      wax.completionWat(src, line, character, defines),
  },
];

export function activateWith(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
): void {
  const log = vscode.window.createOutputChannel("Wax");
  context.subscriptions.push(log);
  log.appendLine("Wax extension activated.");

  for (const lang of LANGUAGES) {
    registerFormatter(context, opts, log, lang);
    registerOutline(context, opts, lang);
    if (lang.hover) registerHover(context, opts, lang);
    if (lang.inlays) registerInlayHints(context, opts, lang);
    if (lang.definition) registerDefinition(context, opts, lang);
    if (lang.typeDefinition) registerTypeDefinition(context, opts, lang);
    if (lang.references) registerReferences(context, opts, lang);
    if (lang.rename) registerRename(context, opts, lang);
    if (lang.completion) registerCompletion(context, opts, lang);
    if (lang.signatureHelp) registerSignatureHelp(context, opts, lang);
    if (lang.semanticTokens) registerSemanticTokens(context, opts, lang);
    if (lang.foldingRanges) registerFoldingRanges(context, opts, lang);
    if (lang.selectionRange) registerSelectionRanges(context, opts, lang);
  }
  registerDiagnostics(context, opts);
  registerInactiveDimming(context, opts);
  registerDefineStatusBar(context);
  registerConvert(context, opts);

  // Warm the runtime now (loadWax caches its promise) so the first format or
  // diagnostics run has no load lag — in particular the first format-on-save.
  // Failures are reported by the formatter/diagnostics paths; ignore here.
  void loadWax(context, opts).catch(() => {});
}

function registerFormatter(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  log: vscode.OutputChannel,
  lang: LanguageSpec,
): void {
  let warnedLoadFailure = false;

  const provider: vscode.DocumentFormattingEditProvider = {
    async provideDocumentFormattingEdits(document, _options, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch (err) {
        // A failure to load the runtime must not clobber the buffer; report it
        // loudly (once) so it is not a silent no-op.
        const message =
          err instanceof Error ? err.stack || err.message : String(err);
        log.appendLine("Failed to load the formatter runtime:\n" + message);
        if (!warnedLoadFailure) {
          warnedLoadFailure = true;
          void vscode.window.showErrorMessage(
            "Wax: failed to load the formatter runtime (see the Wax output channel).",
          );
        }
        return [];
      }
      if (token.isCancellationRequested) return [];

      const text = document.getText();
      let result: FormatResult;
      try {
        result = lang.format(wax, text);
      } catch (err) {
        // The wasm runtime can throw a JS error the OCaml layer cannot catch —
        // notably a stack overflow (RangeError) on a very large or deeply nested
        // module, whose printer recursion exceeds the (small) wasm call stack.
        // Report it rather than letting VS Code silently swallow the exception.
        const detail =
          err instanceof RangeError
            ? "the module is too large or deeply nested for the formatter"
            : err instanceof Error
              ? err.message
              : String(err);
        log.appendLine("Formatting failed: " + detail);
        vscode.window.setStatusBarMessage(
          "$(error) Wax: formatting failed — " + detail,
          5000,
        );
        return [];
      }
      if (!result.ok || result.text === null) {
        // Syntax error or similar: leave the document untouched rather than
        // overwrite it (important on format-on-save). Log the detail, and say so
        // in the status bar so the action is not a silent no-op. A transient
        // status-bar message rather than a notification, since format-on-save
        // fires on every save and a popup each time would be noise; the errors
        // themselves are already shown as squiggles and in the Problems panel.
        log.appendLine(
          "Not formatting (input rejected): " + (result.error ?? "unknown"),
        );
        vscode.window.setStatusBarMessage(
          "$(error) Wax: not formatted — the file has syntax errors",
          5000,
        );
        return [];
      }
      if (result.text === text) return []; // already formatted

      const fullRange = new vscode.Range(
        document.positionAt(0),
        document.positionAt(text.length),
      );
      return [vscode.TextEdit.replace(fullRange, result.text)];
    },
  };

  context.subscriptions.push(
    vscode.languages.registerDocumentFormattingEditProvider(lang.id, provider),
  );
}

function symbolKind(kind: string): vscode.SymbolKind {
  switch (kind) {
    case "function":
      return vscode.SymbolKind.Function;
    case "variable":
      return vscode.SymbolKind.Variable;
    case "type":
      return vscode.SymbolKind.Struct;
    case "event":
      return vscode.SymbolKind.Event;
    case "memory":
      return vscode.SymbolKind.Object;
    case "table":
    case "array":
      return vscode.SymbolKind.Array;
    case "namespace":
      return vscode.SymbolKind.Namespace;
    default:
      return vscode.SymbolKind.Variable;
  }
}

function registerOutline(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const build = (s: WaxSymbol): vscode.DocumentSymbol => {
    const range = new vscode.Range(
      s.startLine,
      s.startChar,
      s.endLine,
      s.endChar,
    );
    const selection = new vscode.Range(
      s.selStartLine,
      s.selStartChar,
      s.selEndLine,
      s.selEndChar,
    );
    const symbol = new vscode.DocumentSymbol(
      s.name,
      "",
      symbolKind(s.kind),
      range,
      selection,
    );
    symbol.children = s.children.map(build);
    return symbol;
  };

  const provider: vscode.DocumentSymbolProvider = {
    async provideDocumentSymbols(document, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return [];
      }
      if (token.isCancellationRequested) return [];
      return lang.symbols(wax, document.getText()).map(build);
    },
  };

  context.subscriptions.push(
    vscode.languages.registerDocumentSymbolProvider(lang.id, provider),
  );
}

function registerHover(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const hover = lang.hover;
  if (!hover) return;

  const provider: vscode.HoverProvider = {
    async provideHover(document, position, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return undefined;
      }
      if (token.isCancellationRequested) return undefined;
      let result: WaxHover | null;
      try {
        result = hover(
          wax,
          document.getText(),
          position.line,
          position.character,
        );
      } catch {
        // A runtime error (e.g. a stack overflow on a deeply nested module)
        // must not surface as a failed hover popup; just show nothing.
        return undefined;
      }
      if (!result) return undefined;
      const range = new vscode.Range(
        result.startLine,
        result.startChar,
        result.endLine,
        result.endChar,
      );
      // Render the type in a Wax code block so it picks up syntax colouring.
      const md = new vscode.MarkdownString();
      md.appendCodeblock(result.type, "wax");
      return new vscode.Hover(md, range);
    },
  };

  context.subscriptions.push(
    vscode.languages.registerHoverProvider(lang.id, provider),
  );
}

function registerInlayHints(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const inlays = lang.inlays;
  if (!inlays) return;

  const provider: vscode.InlayHintsProvider = {
    async provideInlayHints(document, range, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return [];
      }
      if (token.isCancellationRequested) return [];
      let hints: WaxInlay[];
      try {
        hints = inlays(wax, document.getText());
      } catch {
        return [];
      }
      // The toolchain returns every hint in the buffer; keep those the editor
      // asked for (the visible range).
      return hints
        .filter((h) => range.contains(new vscode.Position(h.line, h.char)))
        .map(
          (h) =>
            // No padding: the hint anchors right after the name and before the
            // existing space, so ": i32" reads exactly as if it were written.
            new vscode.InlayHint(
              new vscode.Position(h.line, h.char),
              h.label,
              vscode.InlayHintKind.Type,
            ),
        );
    },
  };

  context.subscriptions.push(
    vscode.languages.registerInlayHintsProvider(lang.id, provider),
  );
}

function registerDefinition(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const definition = lang.definition;
  if (!definition) return;

  const provider: vscode.DefinitionProvider = {
    async provideDefinition(document, position, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return undefined;
      }
      if (token.isCancellationRequested) return undefined;
      let ranges: WaxRange[];
      try {
        ranges = definition(
          wax,
          document.getText(),
          position.line,
          position.character,
        );
      } catch {
        return undefined;
      }
      // Every definition is in the same document (a module field or an
      // enclosing local/label binding).
      return ranges.map(
        (r) =>
          new vscode.Location(
            document.uri,
            new vscode.Range(r.startLine, r.startChar, r.endLine, r.endChar),
          ),
      );
    },
  };

  context.subscriptions.push(
    vscode.languages.registerDefinitionProvider(lang.id, provider),
  );
}

function registerTypeDefinition(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const typeDefinition = lang.typeDefinition;
  if (!typeDefinition) return;

  const provider: vscode.TypeDefinitionProvider = {
    async provideTypeDefinition(document, position, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return undefined;
      }
      if (token.isCancellationRequested) return undefined;
      let ranges: WaxRange[];
      try {
        ranges = typeDefinition(
          wax,
          document.getText(),
          position.line,
          position.character,
        );
      } catch {
        return undefined;
      }
      // A type is declared in the same document (a module-level `type` field).
      return ranges.map(
        (r) =>
          new vscode.Location(
            document.uri,
            new vscode.Range(r.startLine, r.startChar, r.endLine, r.endChar),
          ),
      );
    },
  };

  context.subscriptions.push(
    vscode.languages.registerTypeDefinitionProvider(lang.id, provider),
  );
}

function registerReferences(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const references = lang.references;
  if (!references) return;

  // Every occurrence of the symbol under the cursor, computed once and reused by
  // both providers (they want the same set — all occurrences are in this file).
  const occurrences = async (
    document: vscode.TextDocument,
    position: vscode.Position,
    token: vscode.CancellationToken,
  ): Promise<vscode.Range[]> => {
    let wax: Wax;
    try {
      wax = await loadWax(context, opts);
    } catch {
      return [];
    }
    if (token.isCancellationRequested) return [];
    let ranges: WaxRange[];
    try {
      ranges = references(
        wax,
        document.getText(),
        position.line,
        position.character,
      );
    } catch {
      return [];
    }
    return ranges.map(
      (r) => new vscode.Range(r.startLine, r.startChar, r.endLine, r.endChar),
    );
  };

  context.subscriptions.push(
    vscode.languages.registerReferenceProvider(lang.id, {
      async provideReferences(document, position, _context, token) {
        const ranges = await occurrences(document, position, token);
        return ranges.map((range) => new vscode.Location(document.uri, range));
      },
    }),
    vscode.languages.registerDocumentHighlightProvider(lang.id, {
      async provideDocumentHighlights(document, position, token) {
        const ranges = await occurrences(document, position, token);
        return ranges.map((range) => new vscode.DocumentHighlight(range));
      },
    }),
  );
}

function registerRename(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const renamePrepare = lang.renamePrepare;
  const rename = lang.rename;
  if (!renamePrepare || !rename) return;

  const provider: vscode.RenameProvider = {
    // Refuse (so VS Code shows "cannot rename here") unless the cursor is on a
    // renameable symbol; return its range so the rename box pre-fills the name.
    async prepareRename(document, position, token) {
      const wax = await loadWax(context, opts);
      if (token.isCancellationRequested) throw new Error("cancelled");
      const range = renamePrepare(
        wax,
        document.getText(),
        position.line,
        position.character,
      );
      if (!range)
        throw new Error("You cannot rename this element.");
      return new vscode.Range(
        range.startLine,
        range.startChar,
        range.endLine,
        range.endChar,
      );
    },
    async provideRenameEdits(document, position, newName, token) {
      if (!newName.trim()) throw new Error("The new name must not be empty.");
      const wax = await loadWax(context, opts);
      if (token.isCancellationRequested) return undefined;
      const result = rename(
        wax,
        document.getText(),
        position.line,
        position.character,
        newName,
      );
      if (result.error) throw new Error(result.error);
      const edits = result.edits;
      if (edits.length === 0) return undefined;
      const workspace = new vscode.WorkspaceEdit();
      for (const e of edits) {
        workspace.replace(
          document.uri,
          new vscode.Range(e.startLine, e.startChar, e.endLine, e.endChar),
          e.newText,
        );
      }
      return workspace;
    },
  };

  context.subscriptions.push(
    vscode.languages.registerRenameProvider(lang.id, provider),
  );
}

function completionKind(kind: string): vscode.CompletionItemKind {
  switch (kind) {
    case "function":
      return vscode.CompletionItemKind.Function;
    case "variable":
      return vscode.CompletionItemKind.Variable;
    case "type":
      return vscode.CompletionItemKind.Struct;
    case "event":
      return vscode.CompletionItemKind.Event;
    case "memory":
    case "namespace":
      return vscode.CompletionItemKind.Module;
    case "table":
    case "array":
    case "data":
      return vscode.CompletionItemKind.Field;
    case "field":
      return vscode.CompletionItemKind.Field;
    case "method":
      return vscode.CompletionItemKind.Method;
    case "parameter":
    case "local":
      return vscode.CompletionItemKind.Variable;
    case "keyword":
      return vscode.CompletionItemKind.Keyword;
    default:
      return vscode.CompletionItemKind.Text;
  }
}

function registerCompletion(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const completion = lang.completion;
  if (!completion) return;

  const provider: vscode.CompletionItemProvider = {
    async provideCompletionItems(document, position, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return [];
      }
      if (token.isCancellationRequested) return [];
      const defines = vscode.workspace
        .getConfiguration("wax")
        .get<string[]>("define", []);
      let items: WaxCompletion[];
      try {
        items = completion(
          wax,
          document.getText(),
          position.line,
          position.character,
          defines,
        );
      } catch {
        return [];
      }
      // The editor filters by the typed prefix; every candidate is offered.
      return items.map((c) => {
        const item = new vscode.CompletionItem(
          c.name,
          completionKind(c.kind),
        );
        // The type / signature (icon already conveys the kind); nothing when
        // there is no detail (e.g. a keyword).
        if (c.detail) item.detail = c.detail;
        return item;
      });
    },
  };

  context.subscriptions.push(
    // "." triggers member completion, ":" the "ns::" namespace paths;
    // identifier typing triggers the rest.
    vscode.languages.registerCompletionItemProvider(lang.id, provider, ".", ":"),
  );
}

function registerSignatureHelp(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const signatureHelp = lang.signatureHelp;
  if (!signatureHelp) return;

  const provider: vscode.SignatureHelpProvider = {
    async provideSignatureHelp(document, position, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return null;
      }
      if (token.isCancellationRequested) return null;
      let sig: WaxSignature | null;
      try {
        sig = signatureHelp(
          wax,
          document.getText(),
          position.line,
          position.character,
        );
      } catch {
        return null;
      }
      if (!sig) return null;
      const info = new vscode.SignatureInformation(sig.label);
      // Highlight the active parameter by its [start, end) offsets in the label.
      info.parameters = sig.parameters.map(
        (p) => new vscode.ParameterInformation([p.startOff, p.endOff]),
      );
      const help = new vscode.SignatureHelp();
      help.signatures = [info];
      help.activeSignature = 0;
      help.activeParameter = sig.active;
      return help;
    },
  };

  context.subscriptions.push(
    // "(" opens an argument list, "," advances to the next parameter.
    vscode.languages.registerSignatureHelpProvider(
      lang.id,
      provider,
      "(",
      ",",
    ),
  );
}

function registerSemanticTokens(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const semanticTokens = lang.semanticTokens;
  if (!semanticTokens) return;

  const provider: vscode.DocumentSemanticTokensProvider = {
    async provideDocumentSemanticTokens(document, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return null;
      }
      if (token.isCancellationRequested) return null;
      let toks: WaxSemanticToken[];
      try {
        toks = semanticTokens(wax, document.getText());
      } catch {
        return null;
      }
      const builder = new vscode.SemanticTokensBuilder(SEMANTIC_LEGEND);
      // The bridge returns tokens sorted and non-overlapping, exactly as the
      // builder expects.
      for (const t of toks) {
        const type = SEMANTIC_TYPES.indexOf(t.kind);
        if (type < 0) continue;
        builder.push(t.line, t.character, t.length, type, 0);
      }
      return builder.build();
    },
  };

  context.subscriptions.push(
    vscode.languages.registerDocumentSemanticTokensProvider(
      lang.id,
      provider,
      SEMANTIC_LEGEND,
    ),
  );
}

function registerFoldingRanges(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const foldingRanges = lang.foldingRanges;
  if (!foldingRanges) return;

  const kindOf = (k: string): vscode.FoldingRangeKind | undefined =>
    k === "comment"
      ? vscode.FoldingRangeKind.Comment
      : k === "imports"
        ? vscode.FoldingRangeKind.Imports
        : k === "region"
          ? vscode.FoldingRangeKind.Region
          : undefined;

  const provider: vscode.FoldingRangeProvider = {
    async provideFoldingRanges(document, _context, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return [];
      }
      if (token.isCancellationRequested) return [];
      let folds: WaxFolding[];
      try {
        folds = foldingRanges(wax, document.getText());
      } catch {
        return [];
      }
      return folds.map(
        (f) => new vscode.FoldingRange(f.startLine, f.endLine, kindOf(f.kind)),
      );
    },
  };

  context.subscriptions.push(
    vscode.languages.registerFoldingRangeProvider(lang.id, provider),
  );
}

function registerSelectionRanges(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  lang: LanguageSpec,
): void {
  const selectionRange = lang.selectionRange;
  if (!selectionRange) return;

  const provider: vscode.SelectionRangeProvider = {
    async provideSelectionRanges(document, positions, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch {
        return [];
      }
      if (token.isCancellationRequested) return [];
      return positions.map((position) => {
        let ranges: WaxRange[];
        try {
          ranges = selectionRange(
            wax,
            document.getText(),
            position.line,
            position.character,
          );
        } catch {
          ranges = [];
        }
        // The bridge lists the enclosing spans innermost-first; VS Code wants the
        // innermost `SelectionRange` with `.parent` chaining outward, so fold
        // from the outermost inward.
        let sel: vscode.SelectionRange | undefined;
        for (let i = ranges.length - 1; i >= 0; i--) {
          const r = ranges[i];
          sel = new vscode.SelectionRange(
            new vscode.Range(r.startLine, r.startChar, r.endLine, r.endChar),
            sel,
          );
        }
        // Fall back to the cursor itself when nothing was returned, so the
        // provider still yields a valid (degenerate) range for this position.
        return (
          sel ?? new vscode.SelectionRange(new vscode.Range(position, position))
        );
      });
    },
  };

  context.subscriptions.push(
    vscode.languages.registerSelectionRangeProvider(lang.id, provider),
  );
}

function registerDiagnostics(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
): void {
  const collection = vscode.languages.createDiagnosticCollection("wax");
  context.subscriptions.push(collection);

  const specById = new Map(LANGUAGES.map((l) => [l.id, l]));
  const supported = (document: vscode.TextDocument): LanguageSpec | undefined =>
    specById.get(document.languageId);

  // Debounce per document so we re-check on a pause in typing, not every keystroke.
  const timers = new Map<string, ReturnType<typeof setTimeout>>();

  async function refresh(document: vscode.TextDocument): Promise<void> {
    const lang = supported(document);
    if (!lang) return;
    let wax: Wax;
    try {
      wax = await loadWax(context, opts);
    } catch {
      // The formatter path surfaces load failures; here just skip diagnostics.
      return;
    }
    // Specialize diagnostics to the chosen conditional-compilation defines, so
    // the Problems match a `wax -D … check` (WAT ignores them).
    const defines = vscode.workspace
      .getConfiguration("wax")
      .get<string[]>("define", []);
    const items = lang.check(wax, document.getText(), defines).map((d) => {
      const range = new vscode.Range(
        d.startLine,
        d.startChar,
        d.endLine,
        d.endChar,
      );
      const severity =
        d.severity === "error"
          ? vscode.DiagnosticSeverity.Error
          : vscode.DiagnosticSeverity.Warning;
      // Append the toolchain's hint to the message; surface related labels
      // (e.g. the matching opening delimiter) as related information.
      const message = d.hint ? `${d.message}\n${d.hint}` : d.message;
      const diagnostic = new vscode.Diagnostic(range, message, severity);
      diagnostic.source = "wax";
      // Surface a lint's -W name as the diagnostic code (shown as "wax(name)"
      // in the Problems panel, and usable in rule-based filtering), linking it
      // to the hosted documentation of the lints.
      if (d.warning)
        diagnostic.code = {
          value: d.warning,
          target: vscode.Uri.parse("https://ocsigen.org/wax/cli.html#warnings"),
        };
      // A lint that flags removable/unreachable code is tagged Unnecessary, so
      // VS Code renders the range faded (its greyed-out dead-code style).
      if (d.unnecessary) diagnostic.tags = [vscode.DiagnosticTag.Unnecessary];
      if (d.related.length > 0) {
        diagnostic.relatedInformation = d.related.map(
          (r) =>
            new vscode.DiagnosticRelatedInformation(
              new vscode.Location(
                document.uri,
                new vscode.Range(r.startLine, r.startChar, r.endLine, r.endChar),
              ),
              r.message,
            ),
        );
      }
      return diagnostic;
    });
    collection.set(document.uri, items);
  }

  function schedule(document: vscode.TextDocument): void {
    if (!supported(document)) return;
    const key = document.uri.toString();
    const existing = timers.get(key);
    if (existing) clearTimeout(existing);
    timers.set(
      key,
      setTimeout(() => {
        timers.delete(key);
        void refresh(document);
      }, 300),
    );
  }

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(schedule),
    vscode.workspace.onDidChangeTextDocument((e) => schedule(e.document)),
    vscode.workspace.onDidCloseTextDocument((document) => {
      const key = document.uri.toString();
      const existing = timers.get(key);
      if (existing) clearTimeout(existing);
      timers.delete(key);
      collection.delete(document.uri);
    }),
    // Re-check every open document when the defines change, so diagnostics track
    // the new configuration the way the dimming does.
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration("wax.define")) return;
      for (const document of vscode.workspace.textDocuments) schedule(document);
    }),
  );

  // Check documents already open at activation.
  for (const document of vscode.workspace.textDocuments) schedule(document);
}

// --- Inactive-branch dimming -------------------------------------------------
// With `wax.define` set, dim the `#[if]`/`#[else]` branch bodies the chosen
// configuration makes unreachable — as a preprocessor greys out inactive
// `#ifdef` regions. Applied per visible editor (a decoration), recomputed on
// edit, on the configuration changing, and as editors come and go.
function registerInactiveDimming(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
): void {
  const decoration = vscode.window.createTextEditorDecorationType({
    opacity: "0.5",
  });
  context.subscriptions.push(decoration);
  const defines = () =>
    vscode.workspace.getConfiguration("wax").get<string[]>("define", []);
  const timers = new Map<string, ReturnType<typeof setTimeout>>();

  async function refresh(editor: vscode.TextEditor | undefined): Promise<void> {
    if (!editor || editor.document.languageId !== "wax") return;
    const defs = defines();
    if (defs.length === 0) {
      editor.setDecorations(decoration, []);
      return;
    }
    let wax: Wax;
    try {
      wax = await loadWax(context, opts);
    } catch {
      return;
    }
    let ranges: WaxRange[];
    try {
      ranges = wax.inactiveRanges(editor.document.getText(), defs);
    } catch {
      return;
    }
    editor.setDecorations(
      decoration,
      ranges.map(
        (r) => new vscode.Range(r.startLine, r.startChar, r.endLine, r.endChar),
      ),
    );
  }

  const refreshAll = () =>
    vscode.window.visibleTextEditors.forEach((e) => void refresh(e));

  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((e) => void refresh(e)),
    vscode.window.onDidChangeVisibleTextEditors(() => refreshAll()),
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.document.languageId !== "wax") return;
      const key = e.document.uri.toString();
      const existing = timers.get(key);
      if (existing) clearTimeout(existing);
      timers.set(
        key,
        setTimeout(() => {
          timers.delete(key);
          for (const ed of vscode.window.visibleTextEditors)
            if (ed.document === e.document) void refresh(ed);
        }, 300),
      );
    }),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("wax.define")) refreshAll();
    }),
  );
  refreshAll();
}

// A status-bar item showing the active `wax.define` configuration when a `.wax`
// editor is focused; clicking it edits the set. Makes the conditional-compilation
// lens visible and quick to change, without opening settings.json.
function registerDefineStatusBar(context: vscode.ExtensionContext): void {
  const item = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Right,
    100,
  );
  item.command = "wax.configureDefines";
  context.subscriptions.push(item);
  const defines = () =>
    vscode.workspace.getConfiguration("wax").get<string[]>("define", []);

  const update = () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== "wax") {
      item.hide();
      return;
    }
    const defs = defines();
    item.text = "$(settings-gear) " + (defs.length ? defs.join(", ") : "no defines");
    item.tooltip = new vscode.MarkdownString(
      (defs.length
        ? "Conditional-compilation defines:\n" +
          defs.map((d) => "- `" + d + "`").join("\n")
        : "No conditional-compilation defines set.") +
        "\n\nClick to configure. Inactive `#[if]`/`#[else]` branches are dimmed.",
    );
    item.show();
  };

  context.subscriptions.push(
    vscode.commands.registerCommand("wax.configureDefines", async () => {
      const current = defines();
      const input = await vscode.window.showInputBox({
        title: "Wax conditional-compilation defines",
        prompt: "Space-separated -D bindings, e.g. debug=true arch=wasm64",
        value: current.join(" "),
        ignoreFocusOut: true,
      });
      if (input === undefined) return; // cancelled
      const defs = input.split(/\s+/).filter((s) => s.length > 0);
      const target = vscode.workspace.workspaceFolders
        ? vscode.ConfigurationTarget.Workspace
        : vscode.ConfigurationTarget.Global;
      await vscode.workspace
        .getConfiguration("wax")
        .update("define", defs, target);
    }),
    vscode.window.onDidChangeActiveTextEditor(update),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("wax.define")) update();
    }),
  );
  update();
}

// --- Convert / preview -----------------------------------------------------
// "Show compiled WAT" (from a .wax file) and "Show as Wax" (from a .wat file)
// open the conversion in a read-only virtual document beside the source, kept
// live as the source changes. The virtual document's URI encodes the target
// language in its path extension and keeps the source URI in its query, so the
// content provider can re-read and re-convert on demand. While the source is
// temporarily invalid, the last successful conversion is kept (marked stale)
// rather than blanking the preview.

const PREVIEW_SCHEME = "wax-preview";

// Each source language previews as the other.
const PREVIEW_TARGET: Record<string, "wat" | "wax"> = { wax: "wat", wat: "wax" };

function previewUri(source: vscode.Uri, target: "wat" | "wax"): vscode.Uri {
  // Swap the extension for a readable tab title ("foo.wat"); the query keeps the
  // authoritative source URI (a distinct source therefore gets a distinct URI).
  // The path must begin with "/" (an untitled/in-memory source path may not), so
  // normalise it; no authority is used, which would additionally require that.
  const base = source.path.replace(/\.[^/.]+$/, "");
  const path = (base.startsWith("/") ? base : "/" + base) + "." + target;
  return vscode.Uri.from({
    scheme: PREVIEW_SCHEME,
    path,
    query: source.toString(),
  });
}

// The target language a preview URI produces (from its path extension).
function previewTarget(uri: vscode.Uri): "wat" | "wax" {
  return uri.path.endsWith(".wax") ? "wax" : "wat";
}

// A message rendered as comment lines in the target language, so a preview that
// cannot show real output stays valid-looking and highlighted.
function asComment(target: "wat" | "wax", message: string): string {
  const lead = target === "wat" ? ";; " : "// ";
  return message
    .split("\n")
    .map((line) => lead + line)
    .join("\n");
}

function registerConvert(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
): void {
  const changed = new vscode.EventEmitter<vscode.Uri>();
  // The last successful conversion per preview URI. While the source is
  // temporarily invalid (mid-edit), we keep showing this rather than blanking
  // the preview to an error, so it does not flicker on every keystroke.
  const lastGood = new Map<string, string>();
  // Scheduling: convert immediately when idle (leading edge), and if the source
  // changes while a conversion is running, reconvert once when it finishes
  // (coalesced trailing edge) — so conversions never pile up nor lag behind a
  // fixed interval. [converting] holds previews with a conversion in flight;
  // [dirty] those whose source changed during it.
  const converting = new Set<string>();
  const dirty = new Set<string>();

  const provider: vscode.TextDocumentContentProvider = {
    onDidChange: changed.event,
    async provideTextDocumentContent(uri, token): Promise<string> {
      const key = uri.toString();
      const target = previewTarget(uri);
      // Cannot produce fresh output: keep the last good conversion, prefixed
      // with a stale marker; fall back to the reason only if there is none yet.
      const degraded = (reason: string, detail?: string): string => {
        const prev = lastGood.get(key);
        return prev !== undefined
          ? asComment(
              target,
              `⚠ ${reason} Showing the last successful conversion.`,
            ) +
              "\n\n" +
              prev
          : asComment(target, detail ?? reason);
      };

      try {
        let source: vscode.TextDocument;
        try {
          source = await vscode.workspace.openTextDocument(
            vscode.Uri.parse(uri.query),
          );
        } catch {
          return degraded("The source document is no longer open.");
        }
        if (token.isCancellationRequested) return "";
        let wax: Wax;
        try {
          wax = await loadWax(context, opts);
        } catch {
          return degraded("Failed to load the Wax runtime.");
        }
        const text = source.getText();
        const result = target === "wat" ? wax.toWat(text) : wax.toWax(text);
        if (!result.ok || result.text === null) {
          return degraded(
            "The source has errors.",
            "Conversion failed:\n" + (result.error ?? ""),
          );
        }
        lastGood.set(key, result.text);
        return result.text;
      } finally {
        // This conversion finished. If the source changed while it ran, run one
        // more with the latest text; otherwise the preview is now idle.
        if (dirty.has(key)) {
          dirty.delete(key);
          queueMicrotask(() => changed.fire(uri));
        } else {
          converting.delete(key);
        }
      }
    },
  };

  async function show(target: "wat" | "wax"): Promise<void> {
    const editor = vscode.window.activeTextEditor;
    const from = target === "wat" ? "wax" : "wat";
    if (!editor || editor.document.languageId !== from) {
      void vscode.window.showInformationMessage(
        `Wax: open a .${from} file to convert it to ${target.toUpperCase()}.`,
      );
      return;
    }
    const uri = previewUri(editor.document.uri, target);
    converting.add(uri.toString()); // the open/refresh below runs the first conversion
    changed.fire(uri); // refresh if a stale preview is already open
    let doc = await vscode.workspace.openTextDocument(uri);
    if (doc.languageId !== target)
      doc = await vscode.languages.setTextDocumentLanguage(doc, target);
    await vscode.window.showTextDocument(doc, {
      viewColumn: vscode.ViewColumn.Beside,
      preview: true,
      preserveFocus: true,
    });
  }

  // On a source change: convert now if the preview is idle, else mark it dirty
  // so the running conversion reconverts once it finishes.
  function refreshFor(document: vscode.TextDocument): void {
    const target = PREVIEW_TARGET[document.languageId];
    if (!target) return;
    const uri = previewUri(document.uri, target);
    const key = uri.toString();
    if (converting.has(key)) {
      dirty.add(key);
    } else {
      converting.add(key);
      changed.fire(uri);
    }
  }

  context.subscriptions.push(
    changed,
    vscode.workspace.registerTextDocumentContentProvider(
      PREVIEW_SCHEME,
      provider,
    ),
    vscode.workspace.onDidChangeTextDocument((e) => refreshFor(e.document)),
    vscode.workspace.onDidCloseTextDocument((doc) => {
      if (doc.uri.scheme !== PREVIEW_SCHEME) return;
      const key = doc.uri.toString();
      converting.delete(key);
      dirty.delete(key);
      lastGood.delete(key);
    }),
    vscode.commands.registerCommand("wax.showWat", () => show("wat")),
    vscode.commands.registerCommand("wax.showWax", () => show("wax")),
  );
}
