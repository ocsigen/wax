#!/usr/bin/env bash
#
# fuzz/nightly.sh — the budgeted stochastic campaign tier (scheduled, not per-PR).
#
# Where fuzz/check.sh runs the deterministic guards on committed/generated seeds,
# this builds the corpora and runs the budgeted stochastic + behavioural tier:
# run.sh (oracles over the whole corpus), smith, mutate-wax/-wat/-wasm (both
# byte and structure-aware), a seed-keyed slice of the execution oracles (Node
# plus, when REF is available, the reference-interpreter and mutation oracles),
# and diff-validate. Each campaign exits non-zero on a HIGH-severity finding;
# this script's exit is non-zero iff some campaign did.
#
# SEED defaults to a fresh value each run (announced, so a finding replays with
# the same SEED); override it to reproduce a night. The budgets are split so the
# nightly can spend more time in the high-yield mutation campaigns without
# bloating corpus startup: SMITH_COUNT drives smith.sh, CORPUS_SMITH_COUNT drives
# the extra smith-derived Wax/WAT seeds, the MUTATE_* counts drive the mutation
# campaigns, EXEC_WAST_COUNT drives the behavioural slice (`exec.sh` over a
# deterministic SEED-keyed subset of core .wast files), and DIFF_VALIDATE_COUNT
# drives diff-validate.sh. COUNT and SMITH are still accepted as legacy coarse
# overrides. QUICK=1 shrinks everything for a smoke test. Needs wasm-tools; node
# and the reference interpreter (REF) unlock the execution oracles (campaigns
# lacking their engine skip rather than fail).
# Failing campaigns leave their minimized inputs under fuzz/*-findings/.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/fuzz/lib.sh" # for WASM_TOOLS discovery and the SEED default

export SEED
legacy_count="${COUNT:-}"
legacy_smith="${SMITH:-}"
smith="${SMITH_COUNT:-${legacy_smith:-1000}}"
corpus_smith="${CORPUS_SMITH_COUNT:-${legacy_smith:-500}}"
mutate_wax="${MUTATE_WAX_COUNT:-${MUTATE_COUNT:-${legacy_count:-4000}}}"
mutate_wat="${MUTATE_WAT_COUNT:-${MUTATE_COUNT:-${legacy_count:-6000}}}"
mutate_wasm="${MUTATE_WASM_COUNT:-${legacy_count:-8000}}"
mutate_wasm_struct="${MUTATE_WASM_STRUCT_COUNT:-${mutate_wasm}}"
exec_wast="${EXEC_WAST_COUNT:-64}"
diff_validate="${DIFF_VALIDATE_COUNT:-${legacy_count:-3000}}"
if [ "${QUICK:-0}" = 1 ]; then
  smith=40
  corpus_smith=40
  mutate_wax=100
  mutate_wat=100
  mutate_wasm=100
  mutate_wasm_struct=100
  exec_wast=5
  diff_validate=100
fi

command -v "$WASM_TOOLS" >/dev/null 2>&1 || {
  echo "nightly: wasm-tools not found (every campaign needs it)" >&2
  exit 3
}

echo "nightly campaigns — SEED=$SEED  (replay this run with: SEED=$SEED fuzz/nightly.sh)" >&2
echo "budgets: smith=$smith corpus-smith=$corpus_smith mutate-wax=$mutate_wax mutate-wat=$mutate_wat mutate-wasm=$mutate_wasm mutate-wasm-struct=$mutate_wasm_struct exec-wast=$exec_wast diff-validate=$diff_validate" >&2

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

# Pick a deterministic pseudo-random slice of the core .wast suite keyed by
# $SEED, so the nightly execution oracle explores different files over time while
# still replaying from one seed. The score is a stable checksum of "$SEED:$path".
pick_exec_wasts() {
  local count="$1"
  [ "$count" -gt 0 ] || return 0
  find "$ROOT/test/wasm-test-suite/core" -name '*.wast' -print \
    | while IFS= read -r wast; do
        printf '%s\t%s\n' "$(printf '%s\n' "$SEED:$wast" | cksum | cut -d' ' -f1)" "$wast"
      done \
    | sort -n -k1,1 -k2 \
    | head -n "$count" \
    | cut -f2-
}

# Build the tools and the corpora the campaigns feed on.
dune build src/bin/main.exe src/bin/fuzz_mutate.exe src/bin/fuzz_gen.exe 2>&1 | tail -3 \
  || { echo "nightly: build failed" >&2; exit 3; }
echo "building the wasm corpus (spec suite + curated sources)…" >&2
bash "$ROOT/fuzz/build-corpus.sh" >&2 || { echo "nightly: build-corpus failed" >&2; exit 3; }
echo "building the wax and wat seed corpora (spec + $corpus_smith smith modules each)…" >&2
wax_log="$(mktemp)"
wat_log="$(mktemp)"
bash "$ROOT/fuzz/wax-corpus.sh" "$corpus_smith" >"$wax_log" 2>&1 &
wax_pid=$!
bash "$ROOT/fuzz/wat-corpus.sh" "$corpus_smith" >"$wat_log" 2>&1 &
wat_pid=$!
wait "$wax_pid" || true
wait "$wat_pid" || true
cat "$wax_log" >&2
cat "$wat_log" >&2
rm -f "$wax_log" "$wat_log"

# The campaigns (each is deterministic given SEED and self-reports its replay).
run run.sh
run smith.sh "$smith"
run mutate-wax.sh "$mutate_wax"
run mutate-wat.sh "$mutate_wat"
run mutate-wasm.sh "$mutate_wasm"
run "MODE=struct" mutate-wasm.sh "$mutate_wasm_struct"
if [ "$exec_wast" -gt 0 ]; then
  mapfile -t exec_wasts < <(pick_exec_wasts "$exec_wast")
  if [ ${#exec_wasts[@]} -gt 0 ]; then
    # exec.sh runs the slice under Node; the reference-interpreter oracles cover
    # the proposals Node cannot (GC, SIMD, EH, multi-memory) and the mutation
    # oracle lifts the fixed-suite ceiling. All three skip (exit 2) without their
    # engine, so a machine with neither REF nor node loses only coverage.
    run exec.sh "${exec_wasts[@]}"
    run "MODE=wax" exec-ref.sh "${exec_wasts[@]}"
    # wax-text feeds each module's TEXT to wax (wat->wax->wasm), behaviourally
    # covering from_wasm's WAT reader — the input pipeline the binary modes
    # above cannot reach (text-only miscompiles: symbolic-vs-numeric refs,
    # unsanitizable identifiers, width re-inference).
    run "MODE=wax-text" exec-ref.sh "${exec_wasts[@]}"
    # Same pipeline, but one identifier per module renamed to a Wax-hostile
    # spelling first (semantics-preserving), so a name-hygiene miscompile — an
    # unsanitizable label colliding with a generated one and retargeting a
    # branch — shows up as a behavioural regression against the assertions.
    run "MODE=wax-text" "HOSTILE_SEED=$SEED" exec-ref.sh "${exec_wasts[@]}"
    run exec-mutate.sh "${exec_wasts[@]}"
  fi
fi
run diff-validate.sh "$diff_validate"

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
