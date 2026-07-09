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

# The generated loader locates its .wasm relative to require.main.filename (the
# program entry). The desktop extension loads it with require(), so rewrite that
# to module.filename, which then points at the loader's own installed location.
# (The web host takes the loader's fetch branch instead, where this is unused.)
if ! grep -q 'require\.main\.filename' "$dest/wax_format_js.bc.wasm.js"; then
  echo "error: require.main.filename not found in the loader (wasm_of_ocaml output changed?)" >&2
  exit 1
fi
sed -i 's/require\.main\.filename/module.filename/g' "$dest/wax_format_js.bc.wasm.js"

echo "==> Bundling the extension"
(cd "$here" && node esbuild.mjs "$@")

echo "==> OK. Package with:  (cd $here && npm run package)"
