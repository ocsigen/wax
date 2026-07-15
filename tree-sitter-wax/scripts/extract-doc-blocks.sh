#!/usr/bin/env bash
# Extract every ```wax fenced code block from the docs into individual .wax
# files, so they can be parse-checked. Writes to build/doc-blocks/ (gitignored).
#
# Mirrors the awk recipe used by test/cram-tests/docs-examples.t/run.t. Fence
# variants accepted: ```wax and ```wax,check (the ,check ones are type-checked
# by the docs tooling; syntactically they are the same language).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$here/build/doc-blocks"
rm -rf "$out"
mkdir -p "$out"

n=0
for md in "$repo"/docs/src/*.md; do
  [ -e "$md" ] || continue
  base="$(basename "$md" .md)"
  awk -v out="$out" -v base="$base" '
    /^```wax(,check)?[ \t]*$/ { f=1; n++; fn=sprintf("%s/%s-%03d.wax", out, base, n); next }
    /^```[ \t]*$/ { if (f) { f=0; close(fn) }; next }
    f { print > fn }
  ' "$md"
done

n=$(find "$out" -name '*.wax' | wc -l | tr -d ' ')
echo "Extracted $n wax block(s) into $out"
