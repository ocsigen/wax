#!/usr/bin/env bash
#
# cross-corpus.sh [outdir]
#
# Harvest the in-tree stack-switching and custom-descriptors inputs into the
# valid corpus (default fuzz/corpus/valid, as cross-*.wat). wasm-smith cannot
# emit either proposal, so without this the corpus contains zero `cont` /
# `switch` / `exact` / `descriptor` constructs and the crash oracles never see
# an input that can reach those code paths (the switch-on-exact-continuation
# assert lived there, unreachable to every campaign). Sources:
#
#   * test/wasm-test-suite/core/stack-switching/*.wast and
#     .../custom-descriptors/*.wast — top-level TEXT modules, extracted by
#     wast-extract.js (assert_invalid/assert_malformed modules stay behind).
#   * test/cram-tests/*/*.wat fixtures mentioning the constructs (many are
#     deliberately-invalid negative fixtures; the validity gate drops those).
#
# Harvested as TEXT, not binary: a custom-descriptors module needs the feature
# enabled, and the oracle passes no -X flag — so each such module gets a
# (@feature "custom-descriptors") annotation injected (the self-declaration
# mechanism; a spec .wasm binary could not carry it, having no target_features
# section). Gate: a module enters the corpus iff `wasm-tools validate
# --features all` accepts the (annotated) text (ground-truth valid — negative
# cram fixtures drop here) AND `wax check` accepts it. The wax leg keeps the
# corpus green on the KNOWN, documented wax-vs-suite divergences (the
# br_on_cast nullability relaxations pinned as "type-checking should have
# failed" in test/wasm_test_suite.expected, the switch-tag-subtype strictness
# pinned in its cram test): re-reporting those as FALSE_REJECT on every corpus
# run would be noise — differential validation of the spec modules already
# belongs to the run_wasm_testsuite goldens. This corpus's job is input-space
# coverage for the crash/mutation oracles. Divergent modules are counted and
# listed so a NEW divergence is still visible at harvest time.
# Needs node + wasm-tools; skips cleanly without them.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT="${1:-$ROOT/fuzz/corpus}"
DEST="$OUT/valid"
mkdir -p "$DEST"

command -v node >/dev/null 2>&1 || { echo "cross-corpus: node not found (skipping harvest)" >&2; exit 2; }
command -v "$WASM_TOOLS" >/dev/null 2>&1 || { echo "cross-corpus: wasm-tools not found (skipping harvest)" >&2; exit 2; }

EXTRACT="$(dirname "${BASH_SOURCE[0]}")/wast-extract.js"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A module using a custom-descriptors construct must self-declare the feature
# (see header). The construct set is the gated surface: exact refs, the
# descriptor/describes clauses, and the descriptor instructions.
CD_RE='\((exact|descriptor|describes)[ \t]|\.(new(_default)?_desc|cast_desc_eq|get_desc)\b|br_on_cast_desc_eq'

kept=0 dropped=0 divergent=0

# Gate one candidate .wat into the corpus under name $2 (see the header for the
# two-legged gate; inject the feature declaration first when the text needs it).
# $3 = "always" forces the injection: a module from the custom-descriptors
# suite needs the feature even when it uses no gated SYNTAX — e.g. the
# br_on_cast modules that exercise the proposal's relaxed nullability rule
# with plain refs, which the construct regex cannot see.
harvest() {
  local f="$1" name="$2" inject="${3:-auto}" g="$WORK/cand.wat"
  if { [ "$inject" = always ] || grep -qE "$CD_RE" "$f"; } \
     && ! grep -q '(@feature' "$f"; then
    # Inject after the module head (including its optional $name) so the gated
    # constructs validate flag-free.
    sed -E '0,/^\([[:space:]]*module([[:space:]]+\$[^[:space:]()]+)?/s//& (@feature "custom-descriptors")/' "$f" >"$g"
  else
    cp "$f" "$g"
  fi
  if ! "$WASM_TOOLS" validate --features "$WT_FEATURES" "$g" >/dev/null 2>&1; then
    dropped=$((dropped + 1))
  elif ! timeout -k 5 "$TIMEOUT" "$WAX" check "$g" >/dev/null 2>&1; then
    divergent=$((divergent + 1))
    echo "  divergent (reference accepts, wax rejects — left out): $name" >&2
  else
    cp "$g" "$DEST/$name"
    kept=$((kept + 1))
  fi
}

# 1. Spec-suite proposal scripts, exploded into their top-level text modules.
for wast in "$ROOT"/test/wasm-test-suite/core/stack-switching/*.wast \
            "$ROOT"/test/wasm-test-suite/core/custom-descriptors/*.wast; do
  [ -e "$wast" ] || continue
  base="$(basename "$wast" .wast)"
  dir="$(basename "$(dirname "$wast")")"
  inject=auto
  [ "$dir" = custom-descriptors ] && inject=always
  mkdir -p "$WORK/x"; rm -f "$WORK/x"/*
  node "$EXTRACT" "$wast" "$WORK/x" m >/dev/null 2>&1 || continue
  for m in "$WORK/x"/m-*.wat; do
    [ -e "$m" ] || continue
    harvest "$m" "cross-$dir-$base-$(basename "$m")" "$inject"
  done
done

# 2. Cram fixtures that exercise the proposals (single-module .wat files; the
# negative ones — parse/validation error fixtures — fail the gate and drop).
while IFS= read -r f; do
  rel="$(basename "$(dirname "$f")")-$(basename "$f")"
  harvest "$f" "cross-cram-$rel"
done < <(grep -rlE '\(cont[ \t]|\bswitch[ \t]|\bresume\b|\bsuspend\b|'"$CD_RE" \
           "$ROOT"/test/cram-tests --include='*.wat' 2>/dev/null | sort)

echo "cross-proposal harvest: $kept modules kept, $dropped dropped (failed the reference gate), $divergent divergent (wax rejects, left out — see stderr)"
exit 0
