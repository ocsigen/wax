#!/usr/bin/env bash
#
# null-mutate.sh
#
# Metamorphic, type-preserving injection of bottom-typed values into KNOWN-VALID
# corpus modules, then a round trip. Where bottom-fuzz.sh enumerates bottom
# compositions in isolation, this plants them inside real, intertwined bodies the
# generators never produce — the setting the wasm-smith-only round-trip bugs
# actually arose in. Each base (a corpus `.wasm`, decompiled to unfolded WAT) is
# mutated by wat-null-mutate.awk at PER seed-chosen sites; the mutations are:
#
#   NULL   — a reference operand replaced by a `ref.null` at a matching bottom
#            heap type (a `ref.func` -> `ref.null nofunc`, a `ref.null HT` ->
#            `ref.null bottom(HT)`). Type-perturbing, so the reference decides
#            validity (both-reject is the mutation changing the type, not a bug).
#   SELECT — a value wrapped in `select v v (i32.const 1)` (untyped for a numeric
#            const, typed for a ref): value- and type-preserving, so a VALID mutant
#            by construction whose round trip must stay valid.
#   BRNULL — a nullable ref routed through a `br_on_null`-family passthrough inside
#            a block, semantics-preserving (see the mutator header).
#
# Nets (mirroring unreachable-fuzz.sh's REF arbitration + bottom-fuzz.sh's oracle):
#   OVER_REJECT  (HIGH)  — wax rejects a mutant the reference (REF) accepts.
#   FALSE_ACCEPT (HIGH)  — wax accepts (even -s) a mutant REF parses and rejects.
#   CRASH        (HIGH)  — wax exits outside the contract on the mutant.
#   round-trip   (HIGH)  — a wax-accepted mutant fails fuzz/oracle.sh (round-trip
#                          / emitter-soundness / width / struct-drift). This is the
#                          primary net for the SELECT/BRNULL valid mutants.
# A both-reject mutant (a NULL that changed the type to something invalid) is the
# expected, uninteresting outcome and is not reported; REF unable to parse the
# construct (a proposal its build lacks) is skipped, the round-trip net still runs.
#
# Deterministic given SEED; parallel across bases; findings under
# fuzz/null-mutate-findings/. Exits non-zero on any HIGH. Needs wasm-tools (for
# oracle.sh); REF unlocks the validity differential.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
COUNT="${COUNT:-200}"           # corpus modules to draw
PER="${PER:-4}"                 # mutations per module
CORPUS="${CORPUS:-$ROOT/fuzz/corpus/valid}"
REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
MUT="$(dirname "${BASH_SOURCE[0]}")/wat-null-mutate.awk"
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"
FINDINGS="$ROOT/fuzz/null-mutate-findings"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"
export WAX WASM_TOOLS TIMEOUT WT_FEATURES  # so the child oracle.sh uses the frozen wax

command -v "$WASM_TOOLS" >/dev/null 2>&1 || {
  echo "null-mutate: wasm-tools not found (oracle.sh needs it)" >&2; exit 2; }
[ -d "$CORPUS" ] || { echo "null-mutate: no corpus at $CORPUS (run build-corpus.sh)" >&2; exit 2; }
[ -x "$REF" ] || echo "note: reference interpreter not found at $REF — the validity differential is skipped, round-trip still runs" >&2

# ---- Draw COUNT bases, decompiled to unfolded WAT, that carry a mutation site. --
# The corpus is scanned in a SEED-keyed pseudo-random order (so runs sample
# different modules and a run replays from SEED), and a candidate is kept only if
# wat-null-mutate.awk finds at least one site in it — most corpus modules are pure
# numeric/memory code with no reference/const producer to mutate, so filtering
# here keeps the workers busy instead of skipping.
BASE="$RESULTS/base"; mkdir -p "$BASE"
i=0
while IFS= read -r f; do
  [ "$i" -ge "$COUNT" ] && break
  u="$BASE/b$i.wat"
  case "$f" in
    *.wat)  cp "$f" "$u" ;;
    *.wasm) "$WAX" -i wasm -f wat --unfold "$f" -o "$u" 2>/dev/null || { rm -f "$u"; continue; } ;;
  esac
  if [ "$(awk -v count=1 -f "$MUT" "$u" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    i=$((i + 1))
  else
    rm -f "$u"
  fi
done < <(find "$CORPUS" \( -name '*.wat' -o -name '*.wasm' \) 2>/dev/null \
          | while IFS= read -r f; do
              printf '%s\t%s\n' "$(printf '%s' "$SEED:$f" | cksum | cut -d' ' -f1)" "$f"
            done | sort -n -k1,1 -k2 | cut -f2-)
mapfile -t BASES < <(find "$BASE" -name '*.wat' | sort -V)
NB=${#BASES[@]}
[ "$NB" -gt 0 ] || { echo "no base modules" >&2; exit 2; }

# REF verdict on a wat file: ok | reject | noparse (see bottom-fuzz.sh).
ref_verdict() {
  [ -x "$REF" ] || { echo noparse; return; }
  local err; err="$("$REF" -d "$1" 2>&1 >/dev/null)"
  if [ $? -eq 0 ]; then echo ok
  elif printf '%s' "$err" | grep -q "syntax error"; then echo noparse
  else echo reject; fi
}

# Worker: mutate base [n] at PER sites and check each.
fuzz_one() {
  local in="$1" n="$2" out="" p="$RESULTS/w$2" m nb k b saved w r
  ERRLOG="$p.err"; m="$p.mut.wat"
  # Base must remain wax-valid (corpus noise / proposal REF lacks — skip quietly).
  [ "$(classify_wax check "$in")" = ok ] || { printf 's' >&2; return 0; }
  nb=$(awk -v count=1 -f "$MUT" "$in")
  [ "$nb" -gt 0 ] || { printf 's' >&2; return 0; }

  save() { mkdir -p "$FINDINGS"; saved="$FINDINGS/null-$n-$b.wat"; cp "$m" "$saved"; }

  for ((k = 0; k < PER; k++)); do
    b=$(( (SEED + n * 89 + k * 31) % nb ))
    awk -v k="$b" -f "$MUT" "$in" >"$m"
    w="$(classify_wax check "$m")"
    r="$(ref_verdict "$m")"
    case "$w" in
      crash:*)
        save
        out+="$(finding CRASH HIGH "$(basename "$in") site $b" \
          "${w#crash:} on wax check (saved ${saved#$ROOT/})" \
          "wax check $saved")"$'\n'; printf F >&2 ;;
      rejected)
        if [ "$r" = ok ]; then
          save
          out+="$(finding OVER_REJECT HIGH "$(basename "$in") site $b" \
            "wax rejects a REF-valid null-mutant: $(grep -m1 -i error "$ERRLOG" || true) (saved ${saved#$ROOT/})" \
            "wax check $saved")"$'\n'; printf F >&2
        fi ;;   # both-reject / REF-noparse: expected, silent
      ok)
        if [ "$r" = reject ] && [ "$(classify_wax check -s "$m")" = ok ]; then
          save
          out+="$(finding FALSE_ACCEPT HIGH "$(basename "$in") site $b" \
            "wax accepts (even -s) a REF-invalid null-mutant" \
            "wax check -s $saved")"$'\n'; printf F >&2
        fi
        local tag=unknown; [ "$r" = ok ] && tag=valid
        # LINT_PARITY (always REVIEW) is dropped: the SELECT mutation injects a
        # redundant, constant-condition `select v v 1`, which the simplified wax
        # and the literal wat lint differently by construction — a self-inflicted
        # artifact of the mutation, never a wax signal, and never HIGH.
        local orc; orc="$(bash "$ORACLE" "$m" "$tag" 2>/dev/null | grep -v $'\tLINT_PARITY\t')"
        if [ -n "$orc" ]; then
          save
          out+="$(printf '%s\n' "$orc" | sed "s#$m#$saved#g")"$'\n'
          printf F >&2
        fi ;;
    esac
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$n"
  printf '.' >&2
}

announce_seed "$(basename "$0")"
echo "null-mutate: $NB bases x $PER mutations; JOBS=$JOBS" >&2
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
nf=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); nf=${nf:-0}
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "=================== null-mutate report ==================="
echo "bases: $NB  (x$PER mutations)"
echo "findings: $nf  (HIGH: $h)"
if [ "$nf" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /' | head -40
fi
[ "$h" -gt 0 ] && exit 1
exit 0
