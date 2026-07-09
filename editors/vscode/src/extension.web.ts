// Web (browser worker) entry point. No `require`; the wasm loader's browser
// branch fetches the .wasm, which the runtime serves from memory.

import * as vscode from "vscode";
import { activateWith } from "./extension-common";

export function activate(context: vscode.ExtensionContext): void {
  activateWith(context, {});
}

export function deactivate(): void {}
