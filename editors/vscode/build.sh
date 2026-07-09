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

echo "==> Bundling the extension"
(cd "$here" && node esbuild.mjs "$@")

echo "==> OK. Package with:  (cd $here && npm run package)"
