// Shared activation: register a document formatter for Wax that runs the
// wasm-compiled toolchain in-process. Format-on-save needs no extra code — VS
// Code drives any registered formatter when `editor.formatOnSave` is on.

import * as vscode from "vscode";
import { loadWax, LoadOptions, Wax } from "./wax-runtime";

export function activateWith(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
): void {
  const provider: vscode.DocumentFormattingEditProvider = {
    async provideDocumentFormattingEdits(document, _options, token) {
      let wax: Wax;
      try {
        wax = await loadWax(context, opts);
      } catch (err) {
        // A failure to load the runtime must not clobber the buffer; report it
        // and format nothing.
        console.error("wax: failed to load the formatter runtime", err);
        return [];
      }
      if (token.isCancellationRequested) return [];

      const text = document.getText();
      const result = wax.format(text);
      if (!result.ok || result.text === null) {
        // Syntax error or similar: leave the document untouched rather than
        // overwrite it (important on format-on-save).
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
