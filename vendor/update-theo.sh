#!/usr/bin/env bash

version=0.1

set -e -o pipefail

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

rm -rf theo
mkdir -p theo/src

(
    cd $TMP
    git clone https://github.com/vouillon/theo.git
    cd theo
    #git checkout $version
)

SRC=$TMP/theo

cp -v $SRC/LICENSE theo
cp -v $SRC/src/lib-theo/theo.ml theo
cp -v $SRC/src/lib-theo/theo.mli theo

git checkout theo/dune
git add -A .
