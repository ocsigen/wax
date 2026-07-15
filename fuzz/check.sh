#!/usr/bin/env bash
#
# fuzz/check.sh — run the deterministic fuzz guards as one CI-ready gate.
#
# Each guard below is deterministic (a fixed SEED and fixed budgets) and exits
# non-zero on a HIGH-severity finding; a guard whose optional dependency
# (wasm-tools) or seed corpus is absent exits 2 and is SKIPPED, not failed. This
# script's exit status is non-zero iff some guard found a HIGH problem, so it can
# gate CI directly. Budgets are modest (a few minutes total); raise them for a
# heavier run with e.g. `GEN=2000 COUNT=2000 SEED=... fuzz/check.sh`, or set
# QUICK=1 to shrink them further.
#
# NOT included: the stochastic mutation campaigns (mutate-wax/-wat/-wasm, smith,
# diff-validate) and `run.sh` over the built corpus — those are budgeted/nightly
# tiers that need `build-corpus.sh` first; run them separately. This gate is the
# self-contained, per-PR tier.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SEED="${SEED:-1}"

# Per-PR budgets (small); a heavier run overrides GEN / COUNT in the environment.
gen="${GEN:-200}"
count="${COUNT:-200}"
if [ "${QUICK:-0}" = 1 ]; then gen=60; count=60; fi

fail=0 passed=0 skipped=0 failed_list=""

# Run one guard: exit 0 = pass, 2 = skip (missing dep/seeds), anything else =
# a HIGH finding (fail). Extra env (GEN=/COUNT=) is passed as leading VAR=val
# words before the script name.
run() {
  local envs=() name
  while [[ "$1" == *=* ]]; do envs+=("$1"); shift; done
  name="$1"; shift
  printf '\n──────── %s %s ────────\n' "$name" "${envs[*]}" >&2
  env "${envs[@]}" bash "$ROOT/fuzz/$name" "$@"
  local rc=$?
  case $rc in
    0) passed=$((passed + 1)); echo ">> $name: OK" >&2 ;;
    2) skipped=$((skipped + 1)); echo ">> $name: SKIPPED (missing dependency or seeds)" >&2 ;;
    *) fail=$((fail + 1)); failed_list="$failed_list $name"; echo ">> $name: FAILED (exit $rc)" >&2 ;;
  esac
}

# Build the tools the guards drive (a stale binary would test old code).
dune build src/bin/main.exe src/bin/fuzz_gen.exe src/bin/fuzz_recover.exe 2>&1 | tail -3 || {
  echo "check.sh: build failed" >&2; exit 3;
}

# Deterministic cross-cutting guards (self-contained).
run cast-lattice.sh
run drop-width.sh
run stress.sh
run "ITERS=$((count * 25))" "WORKERS=2" recover-fuzz.sh
run wat-cast-chain.sh
run wat-cast-const.sh
run comment-preserve.sh

# Generator campaigns (deterministic given SEED; self-generating inputs).
run "GEN=$gen" fold-fuzz.sh
run "COUNT=$count" type-fuzz.sh
run "COUNT=$count" validate-fuzz.sh
run "GEN=$gen" cond-fuzz.sh
run "GEN=$gen" "GEN_FMT=wat" cond-fuzz.sh

echo >&2
echo "==================== fuzz/check.sh summary ====================" >&2
echo "passed: $passed   skipped: $skipped   failed: $fail" >&2
if [ "$fail" -gt 0 ]; then
  echo "FAILED:$failed_list" >&2
  echo "replay a failing guard with: SEED=$SEED <env> fuzz/<name>" >&2
  exit 1
fi
echo "all deterministic guards clean (SEED=$SEED)" >&2
exit 0
