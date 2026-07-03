#!/usr/bin/env bash
#
# validate-fuzz.sh
#
# Fuzz the Wasm validator's REJECTION arms (lib-wasm/validation.ml) with
# malformed-but-close WAT. validation.ml is a per-instruction type checker whose
# accept path the corpus exercises well (every corpus module is well-typed) but
# whose rejection arms ("this instruction expects i32 but the stack has f64") it
# never reaches; the mutate-wat literal fuzzer perturbs numbers, not types, so it
# does not reach them either.
#
# wat-type-mutate.awk flips ONE value type in a valid module (decompiled from the
# wasm corpus, for instruction variety), so validation runs normally until the
# one now-ill-typed instruction and takes its rejection arm. Each mutant is run
# through a differential against the reference validator, both under STRICT
# validation (-s / --features all) so their reference-resolution strictness
# matches and only type divergences remain:
#
#   The base is valid and the flip makes it ill-typed, so wax (`wax check -s`)
#   and the reference should both REJECT (agreement = the rejection arm was
#   covered). To attribute any split to the flip and not to a pre-existing
#   corpus-module quirk, a base is skipped unless wax AND the reference already
#   agree it is valid. Then the splits are the findings:
#
#   FALSE_ACCEPT — wax accepts a module the reference rejects: the flip made it
#                  ill-typed yet wax's validator missed it. REVIEW.
#   OVER_REJECT  — the reverse; usually the flip was type-preserving for the
#                  reference. REVIEW.
#   CRASH        — validation exits other than ok/rejected. HIGH.
#
# Deterministic given SEED. Needs wasm-tools. Parallel; exits non-zero on any
# HIGH finding (crashes; the differential splits are REVIEW for human triage).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v "$WASM_TOOLS" >/dev/null 2>&1; then
  echo "validate-fuzz: wasm-tools not found (needed as the differential oracle)" >&2
  exit 2
fi

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
COUNT="${COUNT:-800}"       # base modules to decompile from the corpus and mutate
CORPUS="${CORPUS:-$ROOT/fuzz/corpus/valid}"
MUT="$(dirname "${BASH_SOURCE[0]}")/wat-type-mutate.awk"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Reference validation of a WAT file (all proposals, matching wax's target set).
wt_validate_wat() { "$WASM_TOOLS" validate --features "$WT_FEATURES" "$1" >"$1.err" 2>&1; }

# Build the base set: decompile COUNT corpus .wasm to .wat (instruction variety
# the small .wat corpus lacks), falling back to any .wat already present.
BASE="$RESULTS/base"; mkdir -p "$BASE"
i=0
find "$CORPUS" -name '*.wasm' 2>/dev/null | head -"$COUNT" | while read -r f; do
  "$WAX" -f wat "$f" -o "$BASE/b$i.wat" 2>/dev/null || true
  i=$((i + 1))
done
find "$CORPUS" -name '*.wat' 2>/dev/null | while read -r f; do cp "$f" "$BASE/c$(basename "$f")" 2>/dev/null || true; done
mapfile -t BASES < <(find "$BASE" -name '*.wat' | sort)
NB=${#BASES[@]}
[ "$NB" -gt 0 ] || { echo "no base modules (check $CORPUS)" >&2; exit 2; }

# Worker: mutate base [n] and run the differential.
fuzz_one() {
  local in="$1" n="$2" out="" p="$RESULTS/w$2"
  ERRLOG="$p.err"
  local m="$p.wat"
  # Precondition: only mutate a base on which wax and the reference already AGREE
  # (both accept). Some corpus modules diverge for reasons unrelated to a type
  # flip (a proposal, a name-resolution quirk); mutating those would report the
  # pre-existing divergence, not one the flip introduced. Requiring agreement
  # first isolates the type-mutation as the sole cause of any split below.
  [ "$(classify_wax check -s "$in")" = ok ] || { printf 's' >&2; return 0; }
  wt_validate_wat "$in" || { printf 's' >&2; return 0; }
  awk -v seed="$((SEED + n))" -f "$MUT" "$in" >"$m" 2>/dev/null
  # Strict validation (-s): the reference validates references strictly, so match
  # it — otherwise wax's relaxed default (accepting unknown-name refs) shows up as
  # a spurious FALSE_ACCEPT that has nothing to do with the type flip.
  local wax_v; wax_v="$(classify_wax check -s "$m")"
  case "$wax_v" in
    crash:*)
      out+="$(finding VALIDATE HIGH "$(basename "$in")" "$wax_v on wax check (mutant)" \
        "awk -v seed=$((SEED + n)) -f fuzz/wat-type-mutate.awk $in | wax check /dev/stdin")"$'\n'; printf F >&2 ;;
    ok|rejected)
      local wt_ok=1; wt_validate_wat "$m" && wt_ok=0
      if [ "$wax_v" = ok ] && [ "$wt_ok" != 0 ]; then
        out+="$(finding VALIDATE REVIEW "$(basename "$in")" \
          "FALSE_ACCEPT: wax check accepts, reference rejects: $(head -1 "$m.err")" \
          "awk -v seed=$((SEED + n)) -f fuzz/wat-type-mutate.awk $in >m.wat; wax check -s m.wat; wasm-tools validate m.wat")"$'\n'; printf F >&2
      elif [ "$wax_v" = rejected ] && [ "$wt_ok" = 0 ]; then
        out+="$(finding VALIDATE REVIEW "$(basename "$in")" \
          "OVER_REJECT: wax check rejects, reference accepts" \
          "awk -v seed=$((SEED + n)) -f fuzz/wat-type-mutate.awk $in >m.wat; wax check -s m.wat; wasm-tools validate m.wat")"$'\n'; printf F >&2
      fi ;;
  esac
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$n"
  printf '.' >&2
}

announce_seed "$(basename "$0")"
echo "validate-fuzzing $NB type-mutated modules across $JOBS jobs..." >&2
idx=0
for f in "${BASES[@]}"; do
  ( fuzz_one "$f" "$idx" ) &
  idx=$((idx + 1))
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "=================== validate-fuzz report ==================="
echo "mutated modules: $NB"
echo "findings: $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /' | head -40
fi
[ "$h" -gt 0 ] && exit 1
exit 0
