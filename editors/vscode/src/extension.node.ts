// Desktop (Node) entry point. Passes Node's `require` to the runtime, which the
// wasm loader's Node branch uses to read the .wasm from disk.

import * as vscode from "vscode";
import { activateWith } from "./extension-common";

export function activate(context: vscode.ExtensionContext): void {
  activateWith(context, { nodeRequire: require });
}

export function deactivate(): void {}
