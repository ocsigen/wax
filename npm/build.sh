#!/usr/bin/env bash
#
# Build the npm distribution of the Wax CLI.
#
# The result is a single, cross-platform package: the wasm_of_ocaml JS loader
# (installed as the `wax` bin) plus its WebAssembly module. It runs on any Node
# with WebAssembly GC support — there are no per-OS native binaries, so the same
# package works on Linux, macOS and Windows.
#
# Usage:
#   npm/build.sh [VERSION]     # assemble; optionally stamp package.json version
# Then:
#   cd npm && npm publish
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$root"

echo "==> Building the release wasm binary"
dune build --profile release src/bin/main.bc.wasm.js

src="_build/default/src/bin"
loader="$src/main.bc.wasm.js"
[ -f "$loader" ] || {
  echo "error: build did not produce $loader" >&2
  exit 1
}

echo "==> Assembling the package in $here"
rm -rf "$here/main.bc.wasm.assets" "$here/wax"
mkdir -p "$here/main.bc.wasm.assets"

# The bin is the loader with a Node shebang prepended (dune does not emit one).
# The loader locates its assets in ./main.bc.wasm.assets *next to itself*, so the
# bin and the assets directory must stay co-located and keep that exact name.
{
  printf '#!/usr/bin/env node\n'
  cat "$loader"
} >"$here/wax"
chmod +x "$here/wax"

# Ship only the .wasm module(s); drop any .wasm.map sourcemaps.
cp "$src"/main.bc.wasm.assets/*.wasm "$here/main.bc.wasm.assets/"

# Optional: stamp the version from the argument (e.g. npm/build.sh 0.1.0).
if [ "${1:-}" != "" ]; then
  (cd "$here" && npm version --no-git-tag-version --allow-same-version "$1" >/dev/null)
  echo "==> Set version to $1"
fi

echo "==> Smoke test"
printf 'fn f() -> i32 { 1; }\n' >"$here/.smoke.wax"
out=$(node "$here/wax" -i wax -f wat "$here/.smoke.wax")
rm -f "$here/.smoke.wax"
[ "$out" = "(func \$f (result i32) (i32.const 1))" ] || {
  echo "error: smoke test produced unexpected output:" >&2
  echo "$out" >&2
  exit 1
}

echo "==> OK. Package assembled in $here"
echo "    Publish with:  (cd $here && npm publish)"
