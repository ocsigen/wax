#!/usr/bin/env bash
# Replace vendor/stele with a fresh copy of https://github.com/vouillon/stele.
# Usage: vendor/update-stele.sh [REF]   (REF: a branch, tag or commit; default main)

ref=${1:-main}

set -e -o pipefail

cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

git clone -q https://github.com/vouillon/stele.git $TMP/stele
git -C $TMP/stele checkout -q "$ref"
commit=$(git -C $TMP/stele rev-parse HEAD)

rm -rf stele
mkdir stele
# Only the files upstream tracks, minus its repository-level plumbing.
git -C $TMP/stele archive HEAD | tar -x -C stele
rm -rf stele/.github stele/.gitignore stele/.ocamlformat

git add -A stele
echo "stele updated to $commit"
