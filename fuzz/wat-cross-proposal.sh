#!/usr/bin/env bash
#
# wat-cross-proposal.sh [count]
#
# Cross-proposal mutation fuzzer: grafts one proposal's construct onto a module
# shaped by another (mode=cross of wat-type-mutate.awk — wrap a concrete ref in
# (exact ...), splice a (cont $f) wrapper over a func type, link a struct pair
# with (descriptor)/(describes)), then sweeps wax over the mutant. This is the
# input class no generator reaches: wasm-smith can emit neither stack switching
# nor custom descriptors, and the single-proposal corpus/spec modules never mix
# them — which is exactly where the switch-on-(ref (exact $cont)) assert crash
# lived (verified: reverting that fix makes this campaign go red).
#
# Mutants are NOT expected to stay valid; the oracle is the exit-code contract
# (0 ok / 123 usage / 128 clean rejection are all intended answers): a crash —
# uncaught exception (125/2), signal, timeout — is a HIGH finding. Each mutant
# is swept through `check` plus the wat->wasm and wat->wax conversions (the
# lowering and decompile paths validate-and-then-trust differently), all with
# -X custom-descriptors so the gated arms actually run.
#
# Bases: built-in cross-proposal seeds (always present, so the campaign runs
# without a corpus), the harvested cross-*.wat corpus seeds (cross-corpus.sh),
# and a slice of the plain .wat corpus for breadth. Deterministic given SEED;
# parallel; findings saved under fuzz/cross-findings/. Exits non-zero on HIGH.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
COUNT="${COUNT:-600}"        # total mutants across all bases
CORPUS="${CORPUS:-$ROOT/fuzz/corpus/valid}"
MUT="$(dirname "${BASH_SOURCE[0]}")/wat-type-mutate.awk"
FINDINGS="$ROOT/fuzz/cross-findings"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- Base set: built-in seeds guaranteeing the cross-proposal shapes. ----
BASE="$RESULTS/base"; mkdir -p "$BASE"
seed() { printf '%s\n' "$2" >"$BASE/$1.wat"; }

# A switch whose outer continuation's last parameter is itself a continuation
# reference — one exact-wrap away from the fixed assert.
seed s01_switch '(module
  (type $f (func))
  (type $c (cont $f))
  (type $g (func (param (ref $c))))
  (type $c2 (cont $g))
  (tag $t)
  (func (param (ref null $c2)) (param (ref $c))
    local.get 1
    local.get 0
    switch $c2 $t
    drop))'

# resume/suspend threading cont refs through params and results.
seed s02_resume '(module
  (type $ft (func (param i32) (result i32)))
  (type $ct (cont $ft))
  (tag $yield (param i32) (result i32))
  (func $body (param i32) (result i32) (local.get 0))
  (func (param (ref $ct)) (result i32)
    (block $on (result i32 (ref $ct))
      (resume $ct (on $yield $on) (i32.const 1) (local.get 0))
      (return))
    (drop)
    (return)))'

# Struct/func types with refs in fields — food for all three productions.
seed s03_gc '(module
  (type $vt (func (result i32)))
  (type $node (struct (field (ref null $node)) (field (ref null $vt))))
  (type $leaf (struct (field i32)))
  (func (param (ref $node)) (result (ref null $vt))
    (struct.get $node 1 (local.get 0))))'

# Harvested cross-proposal corpus + a breadth slice of the plain .wat corpus.
i=0
if [ -d "$CORPUS" ]; then
  while IFS= read -r f; do
    cp "$f" "$BASE/c$i.wat"; i=$((i + 1))
  done < <(find "$CORPUS" -name 'cross-*.wat' 2>/dev/null | sort)
  while IFS= read -r f; do
    [ "$i" -ge 400 ] && break
    cp "$f" "$BASE/p$i.wat"; i=$((i + 1))
  done < <(find "$CORPUS" -name '*.wat' ! -name 'cross-*' 2>/dev/null | sort)
fi

mapfile -t BASES < <(find "$BASE" -name '*.wat' | sort)
NB=${#BASES[@]}
[ "$NB" -gt 0 ] || { echo "no base modules" >&2; exit 2; }
PER=$(( (COUNT + NB - 1) / NB )); [ "$PER" -lt 1 ] && PER=1

# Worker: apply PER cross-productions to base [n]; crash-sweep each mutant.
fuzz_one() {
  local in="$1" n="$2" out="" p="$RESULTS/w$2" m k r pipe
  ERRLOG="$p.err"
  m="$p.wat"
  for ((k = 0; k < PER; k++)); do
    awk -v seed="$((SEED + n * 131 + k))" -v mode=cross -f "$MUT" "$in" >"$m" 2>/dev/null
    cmp -s "$in" "$m" && continue # no production applied
    for pipe in "check -X custom-descriptors" \
                "-i wat -f wasm -X custom-descriptors -o $p.out.wasm" \
                "-i wat -f wax -X custom-descriptors -o $p.out.wax"; do
      read -ra args <<<"$pipe"
      r="$(classify_wax "${args[@]}" "$m")"
      case "$r" in
        crash:*)
          mkdir -p "$FINDINGS"
          cp "$m" "$FINDINGS/cross-$n-$k.wat"
          out+="$(finding CROSS HIGH "$(basename "$in") mutant $k" \
            "${r#crash:} on: wax $pipe (saved fuzz/cross-findings/cross-$n-$k.wat)" \
            "awk -v seed=$((SEED + n * 131 + k)) -v mode=cross -f fuzz/wat-type-mutate.awk $in >m.wat; wax $pipe m.wat")"$'\n'
          printf F >&2 ;;
      esac
    done
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$n"
  printf '.' >&2
}

announce_seed "$(basename "$0")"
echo "cross-proposal fuzzing: $NB bases x $PER mutants across $JOBS jobs..." >&2
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
echo "=================== cross-proposal report ==================="
echo "bases: $NB   mutants per base: $PER"
echo "findings: $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /' | head -40
fi
[ "$h" -gt 0 ] && exit 1
exit 0
