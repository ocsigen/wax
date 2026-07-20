#!/usr/bin/env bash
#
# fault-locality.sh
#
# Single-fault locality oracle: plant exactly ONE fault in a valid module —
# retarget one use-site identifier at a fresh unbound name, every definition
# and every other use left intact (wat-fault-mutate.js) — and assert the
# diagnostics stay LOCAL:
#
#   * every reported error is at the fault's line, and
#   * there are at most MAX_ERRORS of them (one unbound-reference report; a
#     small allowance for a same-line companion).
#
# This is the regression guard for the index-space poisoning discipline: when a
# definition's own resolution fails (e.g. its typeuse names an unbound type),
# the definition must still claim its index, so later NUMERIC references keep
# resolving to the right entities. Pre-poisoning, faulting one definition
# shifted every later index — subsequent references silently resolved to the
# WRONG entity and the report cascaded across the module (verified: reverting
# the poisoning makes the built-in seeds fail this oracle). The use-site fault
# direction is deliberate: faulting a DEFINITION whose name N sites use yields
# N unbound-name errors, which is correct behaviour, so the clean O(1)
# invariant belongs to the use-site fault (and the built-in seeds reference
# everything else numerically so a single faulted use is the whole story).
#
#   LOCALITY — an error reported away from the fault line (a cascade or a
#              wrong-entity resolution). HIGH.
#   BLOWUP   — more than MAX_ERRORS errors for one fault (all at the fault
#              line). REVIEW.
#   SILENT   — the fault produced no error at all (an unbound reference was
#              silently accepted). REVIEW.
#   CRASH    — any exit outside the contract. HIGH.
#
# Bases: built-in seeds mirroring the poisoning scenarios (functions, globals,
# tables, tags, types — numeric cross-references, one faultable named use),
# enumerated at EVERY fault site, plus COUNT corpus modules at seed-derived
# fault sites. Deterministic given SEED; parallel; needs node; findings under
# fuzz/fault-findings/. Exits non-zero on any HIGH finding.
#
# The same invariant is checked on the Wax typer: wax-fault-mutate.js retargets
# one .wax use site (a callee, or a branch label — the classes where the
# typer's Error-type discipline provably keeps errors local today; see its
# header for what is deliberately NOT faulted), over built-in Wax seeds plus
# WAX_COUNT modules from the corpus-wax seeds.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "fault-locality: node not found (needed for the mutator)" >&2; exit 2; }

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
COUNT="${COUNT:-200}"        # wat corpus modules to draw (builtins always run)
WAX_COUNT="${WAX_COUNT:-$COUNT}" # wax corpus modules to draw
PER="${PER:-5}"              # fault sites per corpus module
MAX_ERRORS="${MAX_ERRORS:-3}"
CORPUS="${CORPUS:-$ROOT/fuzz/corpus/valid}"
CORPUS_WAX="${CORPUS_WAX:-$ROOT/fuzz/corpus-wax/valid}"
MUT="$(dirname "${BASH_SOURCE[0]}")/wat-fault-mutate.js"
WAXMUT="$(dirname "${BASH_SOURCE[0]}")/wax-fault-mutate.js"
FINDINGS="$ROOT/fuzz/fault-findings"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- Built-in seeds: the poisoning scenarios. Each has numeric
# cross-references (kept aligned only by poisoned index entries) and named
# uses to fault. ----
BASE="$RESULTS/base"; mkdir -p "$BASE"
seed() { printf '%s\n' "$2" >"$BASE/$1.wat"; }

seed s01_func '(module
  (type $t (func (result i32)))
  (func $a (type $t) (i32.const 1))
  (func $b (result i32) (i32.const 2))
  (func (export "f") (result i32) (call 1))
  (func (export "g") (result i32) (call 0)))'

seed s02_global '(module
  (type $t (func))
  (global $g1 (ref null $t) (ref.null $t))
  (global $g2 i32 (i32.const 5))
  (func (export "f") (result i32) (global.get 1)))'

seed s03_table_tag '(module
  (type $t (func (param i32)))
  (table $tab 1 (ref null $t))
  (table 1 funcref)
  (tag $e (type $t))
  (tag (param i64))
  (func (export "f") (result i32) (table.size 1))
  (func (export "g") (param i64) (local.get 0) (throw 1)))'

seed s04_types '(module
  (type $t0 (func))
  (type $s (struct (field (ref null $t0))))
  (type $t2 (func (result i32)))
  (func (export "f") (type 2) (i32.const 3)))'

# Wax built-ins: callee and branch-label faults across the shapes the typer
# resolves through its value/label environments (a call chain, a call through
# `become`, calls as arguments, a labelled loop).
waxseed() { printf '%s\n' "$2" >"$BASE/$1.wax"; }

waxseed s05_wax_calls 'fn helper(x: i32) -> i32 { x + 1; }
fn other() -> i32 { 5; }
#[export]
fn f() -> i32 { helper(other()); }
#[export]
fn g() -> i32 { become other(); }'

waxseed s06_wax_labels 'fn h() -> i32 { 3; }
#[export]
fn f(c: i32) -> i32 {
    '"'"'l: while c {
        br '"'"'l;
    }
    h();
}'

nb_builtin=$(find "$BASE" \( -name '*.wat' -o -name '*.wax' \) | wc -l)
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
i=0
if [ -d "$CORPUS_WAX" ]; then
  # Prefer the smith-derived seeds: they carry real call graphs and hole
  # pipelines (many faultable use sites), where the tiny spec-derived modules
  # mostly have none.
  while IFS= read -r f; do
    [ "$i" -ge "$WAX_COUNT" ] && break
    cp "$f" "$BASE/x$i.wax"
    i=$((i + 1))
  done < <({ find "$CORPUS_WAX" -name 'smith-*.wax' 2>/dev/null | sort
             find "$CORPUS_WAX" -name '*.wax' ! -name 'smith-*' 2>/dev/null | sort; })
fi

mapfile -t BASES < <(find "$BASE" \( -name '*.wat' -o -name '*.wax' \) | sort)
NB=${#BASES[@]}
[ "$NB" -gt 0 ] || { echo "no base modules" >&2; exit 2; }

# Worker: fault base [n] at each chosen use site and assert error locality.
# The mutator (and the mutant's extension, which `wax check` detects the
# format from) follows the base's own extension.
fuzz_one() {
  local in="$1" n="$2" out="" p="$RESULTS/w$2" m nu k f fl errs nerr away r
  local mut ext
  ERRLOG="$p.err"
  case "$in" in
    *.wax) mut="$WAXMUT" ext=wax ;;
    *)     mut="$MUT" ext=wat ;;
  esac
  m="$p.mut.$ext"
  # The base must be wax-valid (a pre-existing rejection is corpus noise here).
  [ "$(classify_wax check "$in")" = ok ] || { printf 's' >&2; return 0; }
  nu="$(node "$mut" "$in" --count 2>/dev/null)"; nu="${nu:-0}"
  [ "$nu" -gt 0 ] || { printf 's' >&2; return 0; }
  local picks=()
  if [[ "$(basename "$in")" == s* ]]; then
    for ((f = 0; f < nu; f++)); do picks+=("$f"); done
  else
    for ((k = 0; k < PER; k++)); do picks+=($(( (SEED + n * 97 + k * 41) % nu ))); done
  fi
  for f in "${picks[@]}"; do
    FAULT="$f" node "$mut" "$in" >"$m" 2>"$p.line" || continue
    fl="$(cat "$p.line")"; [ -n "$fl" ] || continue
    r="$(classify_wax check --error-format short "$m")"
    case "$r" in
      crash:*)
        mkdir -p "$FINDINGS"; cp "$m" "$FINDINGS/fault-$n-$f.$ext"
        out+="$(finding FAULT HIGH "$(basename "$in") fault $f" \
          "${r#crash:} on wax check (saved fuzz/fault-findings/fault-$n-$f.$ext)" \
          "FAULT=$f node $mut $in >m.$ext; wax check m.$ext")"$'\n'
        printf F >&2; continue ;;
    esac
    # Errors only (warnings may legitimately appear elsewhere — faulting a
    # function's one call site rightly makes it unused). classify_wax leaves
    # the diagnostics in ERRLOG.
    errs="$(grep -E '^[^ ]+:[0-9]+:[0-9]+: error: ' "$ERRLOG" || true)"
    nerr=0; [ -n "$errs" ] && nerr="$(printf '%s\n' "$errs" | wc -l)"
    away="$(printf '%s\n' "$errs" | awk -F: -v l="$fl" 'NF > 2 && $2 != l' || true)"
    if [ -n "$away" ]; then
      mkdir -p "$FINDINGS"; cp "$m" "$FINDINGS/fault-$n-$f.$ext"
      out+="$(finding LOCALITY HIGH "$(basename "$in") fault $f (line $fl)" \
        "error away from the fault line: $(head -1 <<<"$away") (saved fuzz/fault-findings/fault-$n-$f.$ext)" \
        "FAULT=$f node $mut $in >m.$ext; wax check --error-format short m.$ext")"$'\n'
      printf F >&2
    elif [ "$nerr" -gt "$MAX_ERRORS" ]; then
      mkdir -p "$FINDINGS"; cp "$m" "$FINDINGS/fault-$n-$f.$ext"
      out+="$(finding BLOWUP REVIEW "$(basename "$in") fault $f (line $fl)" \
        "$nerr errors for one fault (saved fuzz/fault-findings/fault-$n-$f.$ext)" \
        "FAULT=$f node $mut $in >m.$ext; wax check --error-format short m.$ext")"$'\n'
      printf F >&2
    elif [ "$nerr" -eq 0 ]; then
      mkdir -p "$FINDINGS"; cp "$m" "$FINDINGS/fault-$n-$f.$ext"
      out+="$(finding SILENT REVIEW "$(basename "$in") fault $f (line $fl)" \
        "an unbound reference produced no error (verdict $r; saved fuzz/fault-findings/fault-$n-$f.wat)" \
        "FAULT=$f node $mut $in >m.$ext; wax check --error-format short m.$ext")"$'\n'
      printf F >&2
    fi
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$n"
  printf '.' >&2
}

announce_seed "$(basename "$0")"
echo "single-fault locality over $NB bases ($nb_builtin built-in, exhaustive) across $JOBS jobs..." >&2
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
echo "=================== fault-locality report ==================="
echo "bases: $NB"
echo "findings: $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /' | head -40
fi
[ "$h" -gt 0 ] && exit 1
exit 0
