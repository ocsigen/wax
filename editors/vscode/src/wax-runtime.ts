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

export interface WaxRange {
  startLine: number;
  startChar: number;
  endLine: number;
  endChar: number;
}

export interface WaxRelated extends WaxRange {
  message: string;
}

export interface WaxDiagnostic extends WaxRange {
  severity: "error" | "warning";
  message: string;
  // The `-W` name of a lint warning (e.g. "unused-local"), or null.
  warning: string | null;
  // Whether the warning flags removable/unreachable code, for faded rendering
  // (VS Code's DiagnosticTag.Unnecessary).
  unnecessary: boolean;
  hint: string | null;
  related: WaxRelated[];
}

export interface WaxHover extends WaxRange {
  // The rendered type of the expression under the cursor.
  type: string;
}

export interface WaxInlay {
  // Zero-based position the hint is anchored at (the end of the binding name).
  line: number;
  char: number;
  // The hint text, e.g. ": i32".
  label: string;
}

export interface WaxEdit extends WaxRange {
  // Replacement text for this span (a punned field expands to "x: new").
  newText: string;
}

export interface WaxRenameResult {
  // The edits to apply, empty when the position is not a renameable symbol.
  edits: WaxEdit[];
  // A message rejecting the rename, or null when it is allowed.
  error: string | null;
}

export interface WaxCompletion {
  name: string;
  // "function" | "variable" | "type" | "event" | "memory" | "table" | "array" |
  // "data" | "namespace" | "parameter" | "local" | "keyword" | "field".
  kind: string;
  // A one-line type / signature (e.g. "fn(a: i32) -> i32", "i32"), or "".
  detail: string;
}

export interface WaxSignature {
  // The callee's rendered signature, e.g. "fn(a: i32, b: i32) -> i32".
  label: string;
  // The [start, end) offset of each parameter within `label`, for highlighting.
  parameters: { startOff: number; endOff: number }[];
  // Index into `parameters` of the argument the cursor is on.
  active: number;
}

export interface WaxSemanticToken {
  line: number;
  character: number;
  length: number;
  // One of the legend types: "namespace" | "type" | "function" | "parameter" |
  // "variable" | "property".
  kind: string;
}

export interface WaxFolding {
  startLine: number;
  endLine: number;
  // "region" (a block body), "comment" (a block comment), or "imports".
  kind: string;
}

export interface WaxSymbol {
  name: string;
  kind: string;
  startLine: number;
  startChar: number;
  endLine: number;
  endChar: number;
  selStartLine: number;
  selStartChar: number;
  selEndLine: number;
  selEndChar: number;
  children: WaxSymbol[];
}

export interface Wax {
  // Wax language.
  format(src: string): FormatResult;
  // Diagnostics, specialized to the given conditional-compilation defines
  // (mirroring `-D`); an empty array runs the all-configurations check.
  check(src: string, defines: string[]): WaxDiagnostic[];
  // The type of the innermost expression at the (zero-based) position, or null
  // if there is none. Wax only — WAT builds no typed tree.
  hover(src: string, line: number, character: number): WaxHover | null;
  // Inferred-type inlay hints, one per un-annotated `let` binding. Wax only.
  inlays(src: string): WaxInlay[];
  // Definition span(s) of the name/label use at the (zero-based) position, for
  // go-to-definition; several only across conditional branches. Wax only.
  definition(src: string, line: number, character: number): WaxRange[];
  // Declaration span(s) of the *type* of the value at the position, for
  // go-to-type-definition (e.g. from a `&point` value to `type point`). Empty
  // for a primitive/anonymous/unknown type. Wax only.
  typeDefinition(src: string, line: number, character: number): WaxRange[];
  // Every occurrence (definitions + uses) of the symbol at the position, for
  // find-references and document highlight. Wax only.
  references(src: string, line: number, character: number): WaxRange[];
  // The span of the renameable symbol at the position, or null if none. Wax only.
  renamePrepare(src: string, line: number, character: number): WaxRange | null;
  // Edits renaming the symbol at the position to `newName` (puns expanded), or
  // a non-null `error` message when the rename is rejected (an unusable name, or
  // a change that would clash with an existing name). `edits` is empty when the
  // position is not a renameable symbol. Wax only.
  rename(
    src: string,
    line: number,
    character: number,
    newName: string,
  ): WaxRenameResult;
  symbols(src: string): WaxSymbol[];
  // Names in scope at the position (module defs, the enclosing function's
  // params/locals, keywords), for completion, specialized to the given
  // conditional-compilation defines (an empty array keeps the all-configurations
  // path-sensitive behaviour). Wax only.
  completion(
    src: string,
    line: number,
    character: number,
    defines: string[],
  ): WaxCompletion[];
  // The enclosing call's signature at the position, or null if the cursor is
  // not inside a call to a named function. Wax only.
  signatureHelp(
    src: string,
    line: number,
    character: number,
  ): WaxSignature | null;
  // The chain of enclosing syntactic spans at the position, innermost first, for
  // expand/shrink selection. Wax only.
  selectionRange(src: string, line: number, character: number): WaxRange[];
  // Every classified identifier occurrence, for semantic highlighting. Wax only.
  semanticTokens(src: string): WaxSemanticToken[];
  // Foldable regions — block bodies and multi-line block comments. Wax only.
  foldingRanges(src: string): WaxFolding[];
  // The source ranges made unreachable by the given `-D` defines (dead
  // `#[if]`/`#[else]` branch bodies), for dimming. Empty with no defines. Wax
  // only.
  inactiveRanges(src: string, defines: string[]): WaxRange[];
  // Wasm text (WAT). Same one wasm module.
  formatWat(src: string): FormatResult;
  checkWat(src: string): WaxDiagnostic[];
  symbolsWat(src: string): WaxSymbol[];
  // WAT editor features, on par with the Wax ones above. Hover shows the type an
  // instruction leaves on the stack; definition/references/rename operate on the
  // WAT name-resolution table; folding/selection are structural.
  hoverWat(src: string, line: number, character: number): WaxHover | null;
  definitionWat(src: string, line: number, character: number): WaxRange[];
  referencesWat(src: string, line: number, character: number): WaxRange[];
  renamePrepareWat(
    src: string,
    line: number,
    character: number,
  ): WaxRange | null;
  renameWat(
    src: string,
    line: number,
    character: number,
    newName: string,
  ): WaxEdit[];
  selectionRangeWat(src: string, line: number, character: number): WaxRange[];
  foldingRangesWat(src: string): WaxFolding[];
  semanticTokensWat(src: string): WaxSemanticToken[];
  signatureHelpWat(
    src: string,
    line: number,
    character: number,
  ): WaxSignature | null;
  // Cross-language conversion (for the preview commands).
  toWat(src: string): FormatResult;
  toWax(src: string): FormatResult;
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

  if (isNode) {
    // Desktop: require the loader as a CommonJS module. The build rewrote its
    // require.main.filename to module.filename, so it resolves the .wasm sitting
    // next to it on disk. It self-executes and, once the OCaml top-level
    // finishes, installs globalThis.wax (it does not return a ready-promise, so
    // we poll for the export).
    if (!opts.nodeRequire) {
      throw new Error("wax: nodeRequire is required on the desktop host");
    }
    opts.nodeRequire(loaderUri.fsPath);
    return waitForGlobal<Wax>("wax", 10000);
  }

  // Web: no require and a virtual filesystem, so read the loader, serve its
  // .wasm from memory via a fetch shim (the loader takes its fetch branch here),
  // and run it in a Function. The build's module.filename rewrite is in the
  // loader's Node branch, which never runs on web.
  const loaderSrc = new TextDecoder().decode(
    await vscode.workspace.fs.readFile(loaderUri),
  );
  const wasmName = wasmNameFromLoader(loaderSrc);
  const wasmBytes = await vscode.workspace.fs.readFile(
    vscode.Uri.joinPath(assetsDir, wasmName),
  );
  const restoreFetch = installFetchShim(wasmBytes);
  try {
    new Function("require", loaderSrc)(undefined);
    return await waitForGlobal<Wax>("wax", 10000);
  } finally {
    // The .wasm is fetched during instantiation, before the export appears, so
    // by now the shim has done its job and can be removed.
    restoreFetch();
  }
}

function wasmNameFromLoader(loaderSrc: string): string {
  // The loader bakes in its module list as e.g. "link":[["code-<hash>",0]], and
  // the file on disk is that name + ".wasm". Deriving it from the loader text
  // avoids a readDirectory call, which the web extension host's virtual
  // filesystem rejects (EntryNotADirectory). The release build links a single
  // module, so the first entry is the one we serve.
  const match = loaderSrc.match(/"link":\s*\[\s*\[\s*"([^"]+)"/);
  if (!match) {
    throw new Error("wax: could not find the wasm module name in the loader");
  }
  return match[1] + ".wasm";
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
