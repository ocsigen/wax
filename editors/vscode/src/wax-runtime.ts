// Loads the wasm_of_ocaml build of the Wax formatter and returns the object it
// installs as `globalThis.wax`. Works in both the desktop (Node) and web
// (browser worker) extension hosts. The module is instantiated once and cached.
//
// The generated loader resolves its own .wasm, with heuristics that assume it is
// the program entry — neither survives being shipped inside an extension. So we
// steer each host down its native branch and feed it the assets ourselves:
//
//   * Node  — the loader reads the .wasm with `require("node:fs")` relative to
//     `require.main.filename` (VS Code's entry, not ours). We redirect that to
//     the loader's own on-disk location, where the .wasm sits beside it.
//   * Web   — the loader `fetch`es the .wasm; we install a fetch shim that
//     serves the bytes read through the VS Code filesystem API. `Response` is
//     native in the browser, so there is no Node/undici dependency on that path.

import * as vscode from "vscode";

export interface FormatResult {
  ok: boolean;
  text: string | null;
  error: string | null;
}

export interface Wax {
  format(src: string): FormatResult;
}

export interface LoadOptions {
  // Node's `require`, injected by the desktop entry point (the loader's Node
  // branch calls it). Omitted on web, where that branch never runs.
  nodeRequire?: NodeRequire;
}

const isNode =
  typeof process !== "undefined" && !!process.versions && !!process.versions.node;

let cached: Promise<Wax> | undefined;

/** Instantiate the formatter once; later calls share the same instance. */
export function loadWax(
  context: vscode.ExtensionContext,
  opts: LoadOptions = {},
): Promise<Wax> {
  return (cached ??= bootstrap(context, opts));
}

async function bootstrap(
  context: vscode.ExtensionContext,
  opts: LoadOptions,
): Promise<Wax> {
  const dir = vscode.Uri.joinPath(context.extensionUri, "dist", "wax");
  const loaderUri = vscode.Uri.joinPath(dir, "wax_format_js.bc.wasm.js");
  const assetsDir = vscode.Uri.joinPath(dir, "wax_format_js.bc.wasm.assets");

  let loaderSrc = new TextDecoder().decode(
    await vscode.workspace.fs.readFile(loaderUri),
  );

  let restoreFetch: (() => void) | undefined;

  if (isNode) {
    loaderSrc = loaderSrc
      .split("require.main.filename")
      .join("globalThis.__waxLoaderFile");
    (globalThis as Record<string, unknown>).__waxLoaderFile = loaderUri.fsPath;
  } else {
    const wasmName = await findWasm(assetsDir);
    const wasmBytes = await vscode.workspace.fs.readFile(
      vscode.Uri.joinPath(assetsDir, wasmName),
    );
    restoreFetch = installFetchShim(wasmBytes);
  }

  try {
    // Run the loader in its own scope with `require` injected. It self-executes
    // and, once the OCaml top-level finishes, installs globalThis.wax. The
    // loader does not hand back its ready-promise, so poll for the export.
    new Function("require", loaderSrc)(opts.nodeRequire);
    return await waitForGlobal<Wax>("wax", 10000);
  } finally {
    // The .wasm is fetched during instantiation, before the export appears, so
    // by now the shim has done its job and can be removed.
    restoreFetch?.();
  }
}

async function findWasm(assetsDir: vscode.Uri): Promise<string> {
  // The .wasm carries a content hash in its name; read whichever one is there
  // rather than hardcoding the hash.
  const entries = await vscode.workspace.fs.readDirectory(assetsDir);
  const wasm = entries.find(([name]) => name.endsWith(".wasm"));
  if (!wasm) throw new Error(`wax: no .wasm found in ${assetsDir.toString()}`);
  return wasm[0];
}

function installFetchShim(bytes: Uint8Array): () => void {
  // Capture the current fetch by descriptor, never by reading the property: on
  // Node, reading the lazy `fetch` getter would initialise undici. (We only
  // reach this branch on web, but stay defensive.)
  const previous = Object.getOwnPropertyDescriptor(globalThis, "fetch");
  (globalThis as Record<string, unknown>).fetch = async (input: unknown) => {
    if (String(input).endsWith(".wasm")) {
      // Uint8Array is a valid BodyInit at runtime; the cast placates the DOM
      // lib's generic BufferSource typing.
      return new Response(bytes as unknown as BodyInit, {
        headers: { "content-type": "application/wasm" },
      });
    }
    throw new Error(`wax: unexpected fetch for ${String(input)}`);
  };
  return () => {
    if (previous) Object.defineProperty(globalThis, "fetch", previous);
    else delete (globalThis as Record<string, unknown>).fetch;
  };
}

function waitForGlobal<T>(name: string, timeoutMs: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      const value = (globalThis as Record<string, unknown>)[name];
      if (value) return resolve(value as T);
      if (Date.now() - start > timeoutMs) {
        return reject(
          new Error(`wax: runtime did not initialise within ${timeoutMs}ms`),
        );
      }
      setTimeout(tick, 5);
    };
    tick();
  });
}
