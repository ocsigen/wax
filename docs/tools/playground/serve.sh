#!/usr/bin/env bash
#
# Local dev for the browser playground (PLAYGROUND.md): build the wasm bundle,
# copy the assets into docs/src/playground/ (git-ignored), generate examples.json,
# then serve the book with live reload. Mirrors the deploy.yml steps.
#
# Usage: docs/tools/playground/serve.sh
#
# Requires: dune, node, and mdbook on PATH. Pass extra args through to
# `mdbook serve` (e.g. --port 8080).
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

dest=docs/src/playground
src=_build/default/src/editor

echo "==> Building the playground wasm bundle"
dune build --profile release src/editor/wax_format_js.bc.wasm.js

echo "==> Building the CodeMirror editor bundle"
here=docs/tools/playground
[ -d "$here/node_modules" ] || npm ci --prefix "$here"
npm run build --prefix "$here"

echo "==> Assembling assets in $dest"
mkdir -p "$dest/wax_format_js.bc.wasm.assets"
cp "$src/wax_format_js.bc.wasm.js" "$dest/"
cp "$src"/wax_format_js.bc.wasm.assets/*.wasm "$dest/wax_format_js.bc.wasm.assets/"
cp "$here/wax-editor.bundle.js" "$dest/"
dune exec docs/gen_examples.exe -- docs/src >"$dest/examples.json"

echo "==> Smoke test"
node docs/tools/playground/smoke.js

echo "==> Serving (Ctrl-C to stop)"
exec mdbook serve docs "$@"
