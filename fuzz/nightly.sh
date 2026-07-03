#!/usr/bin/env bash
#
# fuzz/nightly.sh — the budgeted stochastic campaign tier (scheduled, not per-PR).
#
# Where fuzz/check.sh runs the deterministic guards on committed/generated seeds,
# this builds the corpora and runs the mutation / generation campaigns over them:
# run.sh (oracles over the whole corpus), smith, mutate-wax/-wat/-wasm (both
# byte and structure-aware) and diff-validate. Each campaign exits non-zero on a
# HIGH-severity finding; this script's exit is non-zero iff some campaign did.
#
# SEED defaults to a fresh value each run (announced, so a finding replays with
# the same SEED); override it to reproduce a night. Budgets: COUNT mutants per
# mutation campaign and SMITH generated modules (and smith-corpus size); QUICK=1
# shrinks them for a smoke test. Needs wasm-tools (and node for the byte-mutation
# mode of mutate-wasm). Failing campaigns leave their minimized inputs under
# fuzz/*-findings/.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/fuzz/lib.sh" # for WASM_TOOLS discovery and the SEED default

export SEED
count="${COUNT:-2000}"
smith="${SMITH:-500}"
if [ "${QUICK:-0}" = 1 ]; then
  count=100
  smith=40
fi

command -v "$WASM_TOOLS" >/dev/null 2>&1 || {
  echo "nightly: wasm-tools not found (every campaign needs it)" >&2
  exit 3
}

echo "nightly campaigns — SEED=$SEED  (replay this run with: SEED=$SEED fuzz/nightly.sh)" >&2

fail=0 passed=0 skipped=0 failed_list=""

# Run one campaign: 0 = clean, 2 = skipped (missing dep/seeds), else = a HIGH
# finding. Leading VAR=val words set env for the campaign.
run() {
  local envs=() name
  while [[ "$1" == *=* ]]; do
    envs+=("$1")
    shift
  done
  name="$1"
  shift
  printf '\n════════ %s %s %s ════════\n' "$name" "${envs[*]}" "$*" >&2
  env "${envs[@]}" bash "$ROOT/fuzz/$name" "$@"
  local rc=$?
  case $rc in
    0) passed=$((passed + 1)); echo ">> $name: OK" >&2 ;;
    2) skipped=$((skipped + 1)); echo ">> $name: SKIPPED" >&2 ;;
    *) fail=$((fail + 1)); failed_list="$failed_list $name"; echo ">> $name: FAILED (exit $rc)" >&2 ;;
  esac
}

# Build the tools and the corpora the campaigns feed on.
dune build src/bin/main.exe src/bin/fuzz_mutate.exe src/bin/fuzz_gen.exe 2>&1 | tail -3 \
  || { echo "nightly: build failed" >&2; exit 3; }
echo "building the wasm corpus (spec suite + curated sources)…" >&2
bash "$ROOT/fuzz/build-corpus.sh" >&2 || { echo "nightly: build-corpus failed" >&2; exit 3; }
echo "building the wax and wat seed corpora (spec + $smith smith modules each)…" >&2
bash "$ROOT/fuzz/wax-corpus.sh" "$smith" >&2 || true
bash "$ROOT/fuzz/wat-corpus.sh" "$smith" >&2 || true

# The campaigns (each is deterministic given SEED and self-reports its replay).
run run.sh
run smith.sh "$smith"
run mutate-wax.sh "$count"
run mutate-wat.sh "$count"
run mutate-wasm.sh "$count"
run "MODE=struct" mutate-wasm.sh "$count"
run diff-validate.sh "$count"

echo >&2
echo "==================== fuzz/nightly.sh summary ====================" >&2
echo "SEED=$SEED   passed: $passed   skipped: $skipped   failed: $fail" >&2
if [ "$fail" -gt 0 ]; then
  echo "FAILED:$failed_list" >&2
  echo "findings saved under fuzz/*-findings/; replay with SEED=$SEED fuzz/<name> <count>" >&2
  exit 1
fi
echo "all campaigns clean (SEED=$SEED)" >&2
exit 0
