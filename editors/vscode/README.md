# Wax for Visual Studio Code

Syntax highlighting, bracket matching, and snippets for
[Wax](https://github.com/ocsigen/wax) — a Rust-like syntax for
WebAssembly — in `.wax` files.

## Features

- **Syntax highlighting** via a TextMate grammar covering the full language:
  keywords and control flow (`fn`, `let`, `do`, `loop`, `match`, `dispatch`,
  `try`/`catch`, the `br*` branch family, stack-switching, …), primitive and
  abstract heap types, references, numeric/char/string literals with escapes,
  labels (`'label`), attributes (`#[export = …]`, `#[if(…)]`, `#[likely]`, …),
  aggregate literals (`{point| …}`, `[bytes| …]`), qualified intrinsics
  (`v128::const_i32x4`, `i64::add128`), and method-style intrinsics.
- **Language configuration**: line/block comments, bracket matching and
  colorization, auto-closing pairs, and indentation rules. Single quotes are
  intentionally *not* auto-closed, because they introduce labels.
- **Snippets** for common constructs (functions, imports/exports, control flow,
  types, tags, memories).

## Installing locally

This extension is not published to the Marketplace. To install it from a checkout:

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
ln -s "$(pwd)/editors/vscode" ~/.vscode/extensions/vouillon.wax-0.1.0
```
2. In modern versions of VS Code, manually placed extensions are not scanned automatically due to caching. You need to register the folder:
   - Open the Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`).
   - Run the command: **`Developer: Install Extension from Location...`**
   - Select the `~/.vscode/extensions/vouillon.wax-0.1.0` folder.

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
