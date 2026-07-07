# Developing the Wax VS Code extension

## Installing locally

To install the extension from a checkout:

### Option A: Install via packaged `.vsix` (Recommended)

Run the following commands to package and install the extension:
```sh
cd editors/vscode
npm install           # installs @vscode/vsce (a dev dependency)
npm run package       # produces wax-<version>.vsix
code --install-extension wax-*.vsix
```

### Option B: Symlink (for development)

1. Symlink (or copy) into your VS Code extensions directory:
```sh
ln -s "$(pwd)/editors/vscode" ~/.vscode/extensions/wax-wasm.wax-0.1.1
```
2. In modern versions of VS Code, manually placed extensions are not scanned automatically due to caching. You need to register the folder:
   - Open the Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`).
   - Run the command: **`Developer: Install Extension from Location...`**
   - Select the `~/.vscode/extensions/wax-wasm.wax-0.1.1` folder.

Then reload VS Code. Any `.wax` file will pick up the `wax` language mode.

## Packaging a `.vsix`

In VS Code you can instead run the **package vsix** build
task — `Terminal → Run Build Task…`, or <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>B</kbd>
(<kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>B</kbd> on macOS) — which invokes the same script.

## Layout

| File | Purpose |
|------|---------|
| `package.json` | Extension manifest (language, grammar, snippet contributions) |
| `language-configuration.json` | Comments, brackets, auto-closing, indentation |
| `syntaxes/wax.tmLanguage.json` | TextMate grammar (`source.wax`) |
| `snippets/wax.json` | Code snippets |

The grammar mirrors the lexer in `src/lib-wax/lexer.ml`; when the language gains
or drops tokens, update the grammar to match.
