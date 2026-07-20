#!/usr/bin/env bash
#
# unreachable-fuzz.sh
#
# Metamorphic oracle on dead-code (principal) typing: inserting `unreachable`
# at any instruction boundary of a valid module preserves validity — the code
# after it validates against the polymorphic stack, and local-init tracking is
# unaffected (no local.set is removed). wasm-smith can never generate a module
# whose VALIDITY depends on how dead code is typed, so this is the only
# systematic exercise of the validator's Bot/Bot_ref arms — the class behind
# the `extern.convert_any` / `any.convert_extern` over-rejection on an
# unreachable stack (verified: reverting that fix makes this campaign go red
# on the built-in convert seed).
#
# Each base is normalized to UNFOLDED wat (one instruction per line), then
# wat-unreachable-insert.awk plants `unreachable` before an instruction line
# inside a function body (never in a folded subtree, a (local ...) header, or
# a global/segment initializer — those wax also prints unfolded, and a constant
# expression legitimately rejects `unreachable`).
#
#   OVER_REJECT — wax rejects the mutant and the spec reference interpreter
#                 (REF, default ~/sources/Wasm/interpreter/wasm) accepts it:
#                 a confirmed dead-code over-rejection. HIGH.
#   REJECT      — wax rejects and REF cannot arbitrate (missing, or it cannot
#                 parse the BASE — e.g. a stack-switching module, a proposal
#                 the REF build lacks). REVIEW.
#   INSERTER    — wax and REF both reject the mutant: the insertion itself
#                 broke validity (an inserter bug to fix, not a wax one). REVIEW.
#   CRASH       — any exit outside the contract. HIGH.
#
# Bases: a built-in convert seed (the motivating shape) enumerated at EVERY
# boundary, plus COUNT corpus modules at RANDOM boundaries (seed-derived).
# Deterministic given SEED; parallel; findings saved under
# fuzz/unreachable-findings/. Exits non-zero on any HIGH finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
COUNT="${COUNT:-300}"        # corpus modules to draw (builtins always run)
PER="${PER:-4}"              # random insertion points per corpus module
CORPUS="${CORPUS:-$ROOT/fuzz/corpus/valid}"
REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
INS="$(dirname "${BASH_SOURCE[0]}")/wat-unreachable-insert.awk"
FINDINGS="$ROOT/fuzz/unreachable-findings"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- Base set: built-in seeds (exhaustive boundaries), then the corpus. ----
BASE="$RESULTS/base"; mkdir -p "$BASE"
seed() { printf '%s\n' "$2" >"$BASE/$1.wat"; }

# The motivating shape: the any<->extern converts mid-body, so one insertion
# lands directly before each — on the polymorphic stack their result must stay
# non-null (principal typing), or the (ref extern) result type rejects.
seed s01_convert '(module
  (func (export "cvt") (param $x (ref extern)) (result (ref extern))
    (extern.convert_any (any.convert_extern (local.get $x)))))'

# Non-null results/branches after the insertion point: ref.as_non_null,
# br_on_non_null and a call all consume from the polymorphic stack.
seed s02_refops '(module
  (type $s (struct (field i32)))
  (func $mk (result (ref $s)) (struct.new $s (i32.const 1)))
  (func (export "f") (param $p (ref null $s)) (result i32)
    (struct.get $s 0 (ref.as_non_null (local.get $p))))
  (func (export "g") (result (ref $s)) (call $mk)))'

nb_builtin=$(find "$BASE" -name '*.wat' | wc -l)
i=0
if [ -d "$CORPUS" ]; then
  while IFS= read -r f; do
    [ "$i" -ge "$COUNT" ] && break
    case "$f" in
      *.wat)  cp "$f" "$BASE/c$i.wat" ;;
      *.wasm) "$WAX" -i wasm -f wat "$f" -o "$BASE/c$i.wat" 2>/dev/null || rm -f "$BASE/c$i.wat" ;;
    esac
    i=$((i + 1))
  done < <(find "$CORPUS" \( -name '*.wat' -o -name '*.wasm' \) 2>/dev/null | sort)
fi

mapfile -t BASES < <(find "$BASE" -name '*.wat' | sort)
NB=${#BASES[@]}
[ "$NB" -gt 0 ] || { echo "no base modules" >&2; exit 2; }

[ -x "$REF" ] || echo "note: reference interpreter not found at $REF — unconfirmed rejections stay REVIEW" >&2

# Worker: unfold base [n], then insert at each chosen boundary and check.
fuzz_one() {
  local in="$1" n="$2" out="" p="$RESULTS/w$2" u m nb ref_base=unknown k b r sev cat
  ERRLOG="$p.err"
  u="$p.unf.wat"; m="$p.mut.wat"
  # Normalize to unfolded; the base must remain wax-valid (corpus noise skip).
  [ "$(classify_wax -i wat -f wat --unfold "$in" -o "$u")" = ok ] || { printf 's' >&2; return 0; }
  [ "$(classify_wax check "$u")" = ok ] || { printf 's' >&2; return 0; }
  nb=$(awk -v count=1 -f "$INS" "$u")
  [ "$nb" -gt 0 ] || { printf 's' >&2; return 0; }
  # Built-in seeds: every boundary. Corpus: PER seed-derived boundaries.
  local picks=()
  if [[ "$(basename "$in")" == s* ]]; then
    for ((b = 0; b < nb; b++)); do picks+=("$b"); done
  else
    for ((k = 0; k < PER; k++)); do picks+=($(( (SEED + n * 89 + k * 31) % nb ))); done
  fi
  for b in "${picks[@]}"; do
    awk -v k="$b" -f "$INS" "$u" >"$m"
    r="$(classify_wax check "$m")"
    case "$r" in
      ok) : ;;
      crash:*)
        mkdir -p "$FINDINGS"; cp "$m" "$FINDINGS/unreachable-$n-$b.wat"
        out+="$(finding UNREACHABLE HIGH "$(basename "$in") boundary $b" \
          "${r#crash:} on wax check (saved fuzz/unreachable-findings/unreachable-$n-$b.wat)" \
          "awk -v k=$b -f fuzz/wat-unreachable-insert.awk <(wax --unfold -f wat $in) | wax check /dev/stdin")"$'\n'
        printf F >&2 ;;
      rejected)
        # Arbitrate with the reference interpreter, when it can read the base.
        if [ "$ref_base" = unknown ]; then
          if [ -x "$REF" ] && "$REF" -d "$u" >/dev/null 2>&1; then ref_base=ok; else ref_base=no; fi
        fi
        cat=REJECT sev=REVIEW
        if [ "$ref_base" = ok ]; then
          if "$REF" -d "$m" >/dev/null 2>&1
          then cat=OVER_REJECT sev=HIGH
          else cat=INSERTER sev=REVIEW
          fi
        fi
        mkdir -p "$FINDINGS"; cp "$m" "$FINDINGS/unreachable-$n-$b.wat"
        out+="$(finding "$cat" "$sev" "$(basename "$in") boundary $b" \
          "wax rejects an unreachable-insertion mutant: $(grep -m1 -i error "$ERRLOG" || true) (saved fuzz/unreachable-findings/unreachable-$n-$b.wat)" \
          "wax check fuzz/unreachable-findings/unreachable-$n-$b.wat")"$'\n'
        printf F >&2 ;;
    esac
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$n"
  printf '.' >&2
}

announce_seed "$(basename "$0")"
echo "unreachable-inserting over $NB bases ($nb_builtin built-in, exhaustive) across $JOBS jobs..." >&2
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
echo "=================== unreachable-fuzz report ==================="
echo "bases: $NB"
echo "findings: $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /' | head -40
fi
[ "$h" -gt 0 ] && exit 1
exit 0
