// Shared activation: register a document formatter for Wax and publish
// diagnostics (syntax / type / lint), both computed by the wasm-compiled
// toolchain in-process. Format-on-save needs no extra code — VS Code drives any
// registered formatter when `editor.formatOnSave` is on.

import * as vscode from "vscode";
import { loadWax, LoadOptions, Wax, WaxSymbol } from "./wax-runtime";

export function activateWith(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
): void {
  const log = vscode.window.createOutputChannel("Wax");
  context.subscriptions.push(log);
  log.appendLine("Wax extension activated.");

  registerFormatter(context, opts, log);
  registerDiagnostics(context, opts);
  registerOutline(context, opts);

  // Warm the runtime now (loadWax caches its promise) so the first format or
  // diagnostics run has no load lag — in particular the first format-on-save.
  // Failures are reported by the formatter/diagnostics paths; ignore here.
  void loadWax(context, opts).catch(() => {});
}

function registerFormatter(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
  log: vscode.OutputChannel,
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
      const result = wax.format(text);
      if (!result.ok || result.text === null) {
        // Syntax error or similar: leave the document untouched rather than
        // overwrite it (important on format-on-save). Log why.
        log.appendLine(
          "Not formatting (input rejected): " + (result.error ?? "unknown"),
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
    vscode.languages.registerDocumentFormattingEditProvider("wax", provider),
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
      return wax.symbols(document.getText()).map(build);
    },
  };

  context.subscriptions.push(
    vscode.languages.registerDocumentSymbolProvider("wax", provider),
  );
}

function registerDiagnostics(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
): void {
  const collection = vscode.languages.createDiagnosticCollection("wax");
  context.subscriptions.push(collection);

  // Debounce per document so we re-check on a pause in typing, not every keystroke.
  const timers = new Map<string, ReturnType<typeof setTimeout>>();

  async function refresh(document: vscode.TextDocument): Promise<void> {
    if (document.languageId !== "wax") return;
    let wax: Wax;
    try {
      wax = await loadWax(context, opts);
    } catch {
      // The formatter path surfaces load failures; here just skip diagnostics.
      return;
    }
    const items = wax.check(document.getText()).map((d) => {
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
    if (document.languageId !== "wax") return;
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
  );

  // Check documents already open at activation.
  for (const document of vscode.workspace.textDocuments) schedule(document);
}
