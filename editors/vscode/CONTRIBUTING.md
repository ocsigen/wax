# Developing the Wax VS Code extension

## Installing locally

To install the extension from a checkout:

Packaging builds the formatter, so you need the OCaml toolchain set up first
(`opam install . --deps-only` from the repo root; `dune` on `PATH`). The build
compiles `src/editor/wax_format_js.ml` to WebAssembly and bundles the extension
with esbuild; see `build.sh`.

### Option A: Install via packaged `.vsix` (Recommended)

Run the following commands to package and install the extension:
```sh
cd editors/vscode
npm install           # dev dependencies: vsce, esbuild, typescript, types
npm run package       # builds the wasm + bundles, produces wax-<version>.vsix
code --install-extension wax-*.vsix
```

### Option B: Symlink (for development)

1. Build the bundles and wasm runtime into `dist/`:
```sh
cd editors/vscode
npm install
npm run build         # dune-builds the wasm, then esbuild-bundles into dist/
```
2. Symlink (or copy) into your VS Code extensions directory:
```sh
ln -s "$(pwd)" ~/.vscode/extensions/wax-wasm.wax-0.2.0
```
3. In modern versions of VS Code, manually placed extensions are not scanned automatically due to caching. You need to register the folder:
   - Open the Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`).
   - Run the command: **`Developer: Install Extension from Location...`**
   - Select the `~/.vscode/extensions/wax-wasm.wax-0.2.0` folder.

Then reload VS Code. Any `.wax` file will pick up the `wax` language mode.

## Packaging a `.vsix`

In VS Code you can instead run the **package vsix** build
task, `Terminal → Run Build Task…`, or <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>B</kbd>
(<kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>B</kbd> on macOS), which invokes the same script.

## Layout

| File | Purpose |
|------|---------|
| `package.json` | Extension manifest (language, grammar, snippet, formatter contributions) |
| `language-configuration.json` | Comments, brackets, auto-closing, indentation |
| `syntaxes/wax.tmLanguage.json` | TextMate grammar (`source.wax`) |
| `snippets/wax.json` | Code snippets |
| `src/extension.node.ts`, `src/extension.web.ts` | Host entry points (desktop / web) |
| `src/extension-common.ts` | Registers the document formatter |
| `src/wax-runtime.ts` | Loads the wasm formatter and exposes `globalThis.wax` |
| `build.sh`, `esbuild.mjs` | Build the wasm runtime and bundle the extension |
| `dist/` | Build output (bundles + `dist/wax` runtime); not committed |

The grammar mirrors the lexer in `src/lib-wax/lexer.ml`; when the language gains
or drops tokens, update the grammar to match.

The formatter runtime is the Wax toolchain itself, compiled to WebAssembly from
`src/editor/wax_format_js.ml` (its `Js.export "wax"` installs the `format`
entry point). `build.sh` builds it with `dune` and stages it under `dist/wax`.
