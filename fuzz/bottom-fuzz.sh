#!/usr/bin/env bash
#
# bottom-fuzz.sh
#
# Exhaustive small-depth enumeration of bottom-typed compositions, the cluster
# behind every recent round-trip miscompile. Those bugs were all tiny (<=6
# instruction) compositions of a bottom-typed value (a hole, a `ref.null`, an
# `unreachable` residue) with a type-adaptive surface (`select`, the `br_on_*`
# family, the hierarchy converts `extern.convert_any`/`any.convert_extern`),
# sometimes with an interposed zero-effect statement (`atomic.fence`), in a live
# OR a post-`unreachable` position — found before only by luck in wasm-smith
# volume. bottom-gen.awk enumerates that shape directly: a templated core
# (WRAP·producer·adapter·consumer·sink, ~15k bodies) plus a SEED-driven random
# tail (length 3..8). Each body drops into a fixed scaffolding module (typed
# params/locals, a memory, three named result-typed blocks so a `br_on_*` has a
# valid target in each hierarchy, a trailing `unreachable` to absorb leftover
# stack). Candidates are deduped by their signature (`sort -u`).
#
# Two nets, mirroring the file's contract:
#
#   1. Validity differential vs the spec reference interpreter (REF, default
#      ~/sources/Wasm/interpreter/wasm), the pattern of unreachable-fuzz.sh:
#        OVER_REJECT  (HIGH)  — wax rejects a candidate REF parses and accepts
#                               (the dead-code / principal-typing over-rejection
#                               class, e.g. the extern.convert_any bug).
#        FALSE_ACCEPT (HIGH)  — wax accepts (even under -s) a candidate REF
#                               parses and rejects (typing too lenient).
#      REF is only trusted when it can PARSE the candidate; a construct its build
#      lacks (this 3.0 build has no threads, so `atomic.fence` reads as a syntax
#      error) yields no differential finding — the round-trip net below, backed
#      by wasm-tools, still covers those.
#   2. Round-trip: every wax-ACCEPTED candidate goes through fuzz/oracle.sh
#      (tagged `valid` when REF agreed, else `unknown`) — the full crash /
#      emitter-soundness / round-trip / width / struct-drift suite. This is what
#      actually catches the composition-round-trip bugs (it needs no REF: its
#      arbiter is wasm-tools, which does support threads/GC). A wax CRASH at the
#      check step is its own HIGH finding.
#
# Deterministic given SEED (only the random tail depends on it); parallel across
# JOBS; findings saved under fuzz/bottom-findings/. Exits non-zero on any HIGH.
# Needs wasm-tools (for oracle.sh) and, for the differential, REF.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
COUNT="${COUNT:-3000}"          # random-tail candidates (the core is exhaustive)
ORACLE_EVERY="${ORACLE_EVERY:-1}" # run oracle.sh on every Nth wax-accepted candidate (1 = all)
REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
GEN="$(dirname "${BASH_SOURCE[0]}")/bottom-gen.awk"
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"
FINDINGS="$ROOT/fuzz/bottom-findings"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"
export WAX WASM_TOOLS TIMEOUT WT_FEATURES  # so the child oracle.sh uses the frozen wax

command -v "$WASM_TOOLS" >/dev/null 2>&1 || {
  echo "bottom-fuzz: wasm-tools not found (oracle.sh needs it)" >&2; exit 2; }
[ -x "$REF" ] || echo "note: reference interpreter not found at $REF — the validity differential is skipped, round-trip still runs" >&2

# Drop a body (|-separated instructions) into the scaffolding module at $2.
wrap() {
  local body; body="$(printf '%s\n' "$1" | tr '|' '\n' | sed 's/^/    /')"
  cat >"$2" <<EOF
(module
  (type \$s (struct (field i32)))
  (memory 1)
  (func \$g (result (ref \$s)) (struct.new_default \$s))
  (func (export "f")
    (param \$a i32) (param \$b i64)
    (param \$r (ref null func)) (param \$x (ref null extern)) (param \$n (ref null any)) (param \$s0 (ref null \$s))
    (local \$li i32) (local \$lj i64) (local \$lr (ref null any))
    block \$bany (result (ref null any))
    block \$bi31 (result (ref null i31))
    block \$bfunc (result (ref null func))
$body
    unreachable
    end
    unreachable
    end
    unreachable
    end
    drop
    unreachable))
EOF
}

# REF verdict on a wat file: prints ok | reject | noparse (a construct REF's
# build cannot parse — its syntax-error path — so it cannot arbitrate).
ref_verdict() {
  [ -x "$REF" ] || { echo noparse; return; }
  local err; err="$("$REF" -d "$1" 2>&1 >/dev/null)"
  if [ $? -eq 0 ]; then echo ok
  elif printf '%s' "$err" | grep -q "syntax error"; then echo noparse
  else echo reject; fi
}

# Worker: candidate line $1, index $2.
fuzz_one() {
  local cand="$1" n="$2" out="" p="$RESULTS/w$2"
  local m="$p.wat" saved
  ERRLOG="$p.err"
  wrap "$cand" "$m"
  local w; w="$(classify_wax check "$m")"
  local r; r="$(ref_verdict "$m")"

  save() { mkdir -p "$FINDINGS"; saved="$FINDINGS/bottom-$n.wat"; cp "$m" "$saved"; }

  # A crash classification is re-verified before it is reported: wax is
  # deterministic, so a real crash reproduces, while a transient failure under
  # heavy parallel load does not (run.sh and the mutation fuzzers re-verify for
  # the same reason). Without this a load spike reported three phantom
  # "uncaught-exception" findings on adjacent candidates, all of which exited
  # cleanly when re-checked. Only a finding pays for the second run.
  case "$w" in crash:*) w="$(classify_wax check "$m")" ;; esac

  case "$w" in
    crash:*)
      save
      out+="$(finding CRASH HIGH "bottom-$n" \
        "${w#crash:} on wax check (saved ${saved#$ROOT/})" \
        "wax check $saved")"$'\n'; printf F >&2 ;;
    rejected)
      if [ "$r" = ok ]; then
        save
        out+="$(finding OVER_REJECT HIGH "bottom-$n" \
          "wax rejects a REF-valid bottom composition: $(grep -m1 -i error "$ERRLOG" || true) (saved ${saved#$ROOT/})" \
          "wax check $saved")"$'\n'; printf F >&2
      fi ;;
    ok)
      # FALSE_ACCEPT: REF (which parsed it) rejects what wax accepts even under
      # strict validation — mirror oracle.sh's strict gate to skip the documented
      # relaxed-WAT leniencies.
      if [ "$r" = reject ] && [ "$(classify_wax check -s "$m")" = ok ]; then
        save
        out+="$(finding FALSE_ACCEPT HIGH "bottom-$n" \
          "wax accepts (even -s) a REF-invalid bottom composition" \
          "wax check -s $saved")"$'\n'; printf F >&2
      fi
      # Round-trip net on every wax-accepted candidate (sampled by ORACLE_EVERY).
      if [ $(( n % ORACLE_EVERY )) -eq 0 ]; then
        local tag=unknown; [ "$r" = ok ] && tag=valid
        # LINT_PARITY (always REVIEW) is dropped: the generated bodies are dense
        # with redundant/constant constructs (a select of identical holes, a
        # constant shift), which the simplified wax and the literal wat lint
        # differently by construction — a synthetic-input artifact, never HIGH.
        local orc; orc="$(bash "$ORACLE" "$m" "$tag" 2>/dev/null | grep -v $'\tLINT_PARITY\t')"
        if [ -n "$orc" ]; then
          save
          # Re-home the temp path in oracle.sh's repros to the saved copy.
          out+="$(printf '%s\n' "$orc" | sed "s#$m#$saved#g")"$'\n'
          printf F >&2
        fi
      fi ;;
  esac
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$n"
  printf '.' >&2
}

announce_seed "$(basename "$0")"
CANDS="$RESULTS/cands"
awk -v count="$COUNT" -v seed="$SEED" -f "$GEN" | sort -u >"$CANDS"
NB=$(wc -l <"$CANDS")
echo "bottom-fuzz: $NB candidates (exhaustive core + $COUNT-tail, deduped); JOBS=$JOBS ORACLE_EVERY=$ORACLE_EVERY" >&2

n=0
while IFS= read -r cand; do
  ( fuzz_one "$cand" "$n" ) &
  n=$((n + 1))
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
done <"$CANDS"
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
nf=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); nf=${nf:-0}
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "=================== bottom-fuzz report ==================="
echo "candidates: $NB"
echo "findings: $nf  (HIGH: $h)"
if [ "$nf" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /' | head -40
fi
[ "$h" -gt 0 ] && exit 1
exit 0
