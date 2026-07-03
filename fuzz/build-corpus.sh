#!/usr/bin/env bash
#
# build-corpus.sh [outdir]
#
# Populate a corpus of known-valid (and some known-invalid) modules for the
# oracle to chew on. Two sources:
#   1. test/wasmoo/wasm-source/*.wat   — curated single-module files (valid).
#   2. test/wasm-test-suite/**/*.wast  — the official spec suite, exploded into
#      one .wasm per module by `wasm-tools json-from-wast`. Each command in the
#      generated JSON tags its module as valid (`module`) or invalid
#      (`assert_invalid` / `assert_malformed`).
#
# Output layout (default fuzz/corpus/):
#   valid/*.wat   valid/*.wasm     — feed with EXPECT=valid
#   invalid/*.wasm                 — feed with EXPECT=invalid

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT="${1:-$ROOT/fuzz/corpus}"
rm -rf "$OUT"
mkdir -p "$OUT/valid" "$OUT/invalid"

# 1. Curated wat sources. A file using wax conditional annotations ((@if ...))
# is not a standalone module — it needs -D defines to pick each branch before it
# can be lowered. Rather than drop it (most of these js_of_ocaml runtime modules
# are large and only lightly conditional), SPECIALIZE it: emit it under two
# assignments differing in $wasi (the dominant condition), so both branches of
# the wasi-gated code enter the corpus. The other condition variables ($effects,
# $ocaml_version) are few, so they are pinned. Any assignment that fully resolves
# a file (no leftover @if) contributes a module; a plain file is copied as-is.
# Falls back to skipping conditional files if wax is not built (this step needs
# it; the rest of build-corpus only needs wasm-tools).
COMMON_DEFS="-D oxcaml=false -D cps=false -D jspi=false -D native=true -D effects=cps -D ocaml_version=5.2.0"
n=0; nspec=0; nskip=0
for f in "$ROOT"/test/wasmoo/wasm-source/*.wat; do
  [ -e "$f" ] || continue
  base="$(basename "$f" .wat)"
  if ! grep -q '(@if' "$f"; then
    cp "$f" "$OUT/valid/wasmoo-$base.wat"; n=$((n+1)); continue
  fi
  if [ ! -x "$WAX" ]; then nskip=$((nskip+1)); continue; fi
  for wasi in false true; do
    out="$OUT/valid/wasmoo-$base-wasi_$wasi.wat"
    if "$WAX" -D wasi="$wasi" $COMMON_DEFS -i wat -f wat "$f" -o "$out" 2>/dev/null \
       && ! grep -q '(@if' "$out"; then
      nspec=$((nspec + 1))
    else
      rm -f "$out"
    fi
  done
done
msg="wasmoo .wat: $n plain + $nspec specialized from conditional files"
[ "$nskip" -gt 0 ] && msg="$msg ($nskip skipped — build wax to include them)"
echo "$msg"

# 2. Spec suite, exploded per module. json-from-wast emits module .wasm files
# plus a JSON describing each one; the "type" field gives the ground truth.
command -v jq >/dev/null 2>&1 && HAVE_JQ=1 || HAVE_JQ=0
nv=0; ni=0; nfail=0; nprop=0
while IFS= read -r wast; do
  # Skip spec tests for proposals wax gates OFF by default: their modules need a
  # feature flag (e.g. -X custom-descriptors) that the oracle does not pass, so
  # default wax rejects them and they would show up as spurious FALSE_REJECTs.
  # custom-descriptors is the only validation-affecting one today.
  case "$wast" in
    *custom-descriptors*) nprop=$((nprop + 1)); continue ;;
  esac
  rel="$(echo "${wast#$ROOT/test/wasm-test-suite/}" | tr '/' '-')"
  tmp="$(mktemp -d)"
  if ! "$WASM_TOOLS" json-from-wast "$wast" --output "$tmp/out.json" \
        --wasm-dir "$tmp" >/dev/null 2>&1; then
    nfail=$((nfail+1)); rm -rf "$tmp"; continue
  fi
  if [ "$HAVE_JQ" = 1 ]; then
    # Map each emitted .wasm to valid/invalid via the command type that owns it.
    while IFS=$'\t' read -r kind file; do
      [ -n "$file" ] && [ -f "$tmp/$(basename "$file")" ] || continue
      case "$kind" in
        module) cp "$tmp/$(basename "$file")" "$OUT/valid/$rel-$(basename "$file")"; nv=$((nv+1)) ;;
        assert_invalid|assert_malformed)
          cp "$tmp/$(basename "$file")" "$OUT/invalid/$rel-$(basename "$file")"; ni=$((ni+1)) ;;
      esac
    done < <(jq -r '.commands[] | select(.filename) | [.type, .filename] | @tsv' "$tmp/out.json")
  else
    # No jq: treat every emitted module as valid (json-from-wast only writes
    # .wasm for assemblable modules; invalid ones are usually skipped).
    for w in "$tmp"/*.wasm; do
      [ -e "$w" ] || continue
      cp "$w" "$OUT/valid/$rel-$(basename "$w")"; nv=$((nv+1))
    done
  fi
  rm -rf "$tmp"
done < <(find "$ROOT/test/wasm-test-suite" -name '*.wast')

echo "spec-suite valid modules:   $nv"
echo "spec-suite invalid modules: $ni"
[ "$nfail" -gt 0 ] && echo "spec-suite .wast that json-from-wast could not split: $nfail"
[ "$nprop" -gt 0 ] && echo "spec-suite .wast skipped (off-by-default proposal): $nprop"
[ "$HAVE_JQ" = 0 ] && echo "(install jq to also harvest the invalid-module corpus)"
echo
echo "corpus written to $OUT"
echo "  valid:   $(find "$OUT/valid" -type f | wc -l) files"
echo "  invalid: $(find "$OUT/invalid" -type f | wc -l) files"
