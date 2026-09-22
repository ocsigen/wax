#!/usr/bin/env bash
#
# Build the VS Code extension: compile the Wax formatter to WebAssembly, stage it
# under dist/wax, then bundle the extension for both the desktop (Node) and web
# (browser) hosts.
#
# Usage:
#   editors/vscode/build.sh [--minify]
# Then:
#   cd editors/vscode && npm run package
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

echo "==> Building the Wax formatter wasm (release)"
(cd "$root" && dune build --profile release src/editor/wax_format_js.bc.wasm.js)

src="$root/_build/default/src/editor"
loader="$src/wax_format_js.bc.wasm.js"
[ -f "$loader" ] || {
  echo "error: build did not produce $loader" >&2
  exit 1
}

echo "==> Staging the wasm runtime in dist/wax"
dest="$here/dist/wax"
rm -rf "$dest"
mkdir -p "$dest"
cp "$loader" "$dest/"
cp -r "$src/wax_format_js.bc.wasm.assets" "$dest/"
# Ship only the .wasm module(s); drop the .wasm.map sourcemaps.
rm -f "$dest/wax_format_js.bc.wasm.assets"/*.map

# The generated loader has to locate its .wasm relative to its own installed
# location. Older wasm_of_ocaml spelled that require.main.filename (the program
# entry), which under the desktop extension's require() is VS Code's entry and
# not ours, so it is rewritten to module.filename; newer wasm_of_ocaml already
# emits module.filename, and then there is nothing to do. Neither spelling means
# the output shape changed and the staged loader would look elsewhere for the
# module. (The web host takes the loader's fetch branch instead, where this is
# unused.)
if grep -q 'require\.main\.filename' "$dest/wax_format_js.bc.wasm.js"; then
  sed -i 's/require\.main\.filename/module.filename/g' "$dest/wax_format_js.bc.wasm.js"
elif ! grep -q 'module\.filename' "$dest/wax_format_js.bc.wasm.js"; then
  echo "error: the loader resolves its .wasm through neither require.main.filename nor module.filename (wasm_of_ocaml output changed?)" >&2
  exit 1
fi

echo "==> Bundling the extension"
(cd "$here" && node esbuild.mjs "$@")

echo "==> OK. Package with:  (cd $here && npm run package)"
