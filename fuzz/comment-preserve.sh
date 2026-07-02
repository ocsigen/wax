#!/usr/bin/env bash
#
# comment-preserve.sh
#
# A deterministic guard on comment preservation — a headline feature (wax keeps
# your comments across format and wat<->wax conversion) that every other oracle
# is blind to, because the whole corpus is comment-free (smith output and wax's
# own decompiled output carry none), so the trivia machinery always runs on
# empty input.
#
# It plants uniquely-numbered sentinel comments ([(;SENT<n>;)] / trailing
# [;;SENT<n>]) at every line of a formatted module, then asserts that each
# comment-preserving conversion carries every sentinel through:
#
#   * format:     wat -> wat,  wax -> wax
#   * cross-fmt:  wat -> wax,  wax -> wat   (delimiters are retargeted —
#                 [(;SENT5;)] <-> [/*SENT5*/] — but the SENT<n> content is what
#                 we count, so the grep is delimiter-agnostic)
#
# The invariant: the set of distinct SENT<n> in the output must equal the set
# planted — none silently dropped. A missing sentinel is a HIGH finding naming
# exactly which ids vanished on which conversion (planting *unique* strings makes
# triage a grep). A conversion that outright fails on the commented module (it
# should not — comments are whitespace) is a finding too.
#
# Seeds are the curated spec-source WAT modules (skipping the [(@if)] ones, which
# need -D); the wax-side seeds are those same modules decompiled by wax, so no
# separate wax corpus is needed. Deterministic (planting needs no RNG), parallel
# across cores, exits non-zero on any HIGH finding — it can gate CI.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
SEEDS="${SEEDS:-$ROOT/test/wasmoo/wasm-source}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# The planter: given a formatted (multi-line) module on stdin, emit it with a
# unique sentinel on every line — an own-line block comment before the line
# (leading trivia) and a trailing line comment after it (trailing trivia). Both
# positions are parse-safe in wat and wax (a block comment is whitespace; a line
# comment runs to the end of an already-complete line). AWK is passed the
# comment delimiters so the same planter serves both formats.
PLANT="$RESULTS/plant.awk"
cat >"$PLANT" <<'AWK'
BEGIN { c = 0 }
{
  c++; printf "%sSENT%d%s\n", bo, c, bc     # own-line block comment (leading)
  c++; printf "%s %sSENT%d\n", $0, ln, c    # trailing line comment
}
AWK

# Count of distinct planted sentinels in a file (delimiter-agnostic).
count_sent() { grep -oE 'SENT[0-9]+' "$1" 2>/dev/null | sort -u | wc -l; }
# The sentinel ids present in a file, one per line.
ids_of() { grep -oE 'SENT[0-9]+' "$1" 2>/dev/null | sort -u; }

# Plant sentinels into $1 (a module in format $2) writing $3; block/line comment
# delimiters chosen by format.
plant() {
  local src="$1" fmt="$2" dst="$3" bo bc ln
  case "$fmt" in
    wat) bo='(;' bc=';)' ln=';;' ;;
    wax) bo='/*' bc='*/' ln='//' ;;
  esac
  awk -v bo="$bo" -v bc="$bc" -v ln="$ln" -f "$PLANT" "$src" >"$dst"
}

# Check one comment-preserving conversion of the planted module $planted (format
# $in_fmt, $np sentinels) to $out_fmt. Appends any finding to $OUT.
check_conv() {
  local seed="$1" planted="$2" in_fmt="$3" np="$4" out_fmt="$5" p="$6"
  local out="$p.out.$out_fmt" v
  v="$(classify_wax -i "$in_fmt" -f "$out_fmt" "$planted" -o "$out")"
  if [ "$v" != ok ]; then
    OUT+="$(finding COMMENT HIGH "$seed" "commented module fails $in_fmt->$out_fmt: $v" \
      "wax -i $in_fmt -f $out_fmt <planted $seed>")"$'\n'
    return
  fi
  local nq; nq="$(count_sent "$out")"
  if [ "$nq" -lt "$np" ]; then
    local missing; missing="$(comm -23 <(ids_of "$planted") <(ids_of "$out") | tr '\n' ' ')"
    OUT+="$(finding COMMENT HIGH "$seed" \
      "$in_fmt->$out_fmt dropped $((np - nq))/$np comments: $missing" \
      "wax -i $in_fmt -f $out_fmt <planted $seed>")"$'\n'
  fi
}

# Worker: for a WAT seed, exercise the wat side (wat->wat, wat->wax) and the wax
# side (decompile to wax, then wax->wax, wax->wat). Planting is done on the
# *formatted* module so it is multi-line and canonical.
check_seed() {
  local seed="$1" p="$RESULTS/w${2}" OUT=""
  ERRLOG="$p.err"
  local v
  # ---- wat side ----
  v="$(classify_wax -i wat -f wat "$seed" -o "$p.fmt.wat")"
  if [ "$v" = ok ]; then
    plant "$p.fmt.wat" wat "$p.plant.wat"
    local np; np="$(count_sent "$p.plant.wat")"
    check_conv "$seed" "$p.plant.wat" wat "$np" wat "$p"
    check_conv "$seed" "$p.plant.wat" wat "$np" wax "$p"
  fi
  # ---- wax side (seed decompiled to wax, then formatted) ----
  if [ "$(classify_wax -i wat -f wax "$seed" -o "$p.seed.wax")" = ok ] \
     && [ "$(classify_wax -i wax -f wax "$p.seed.wax" -o "$p.fmt.wax")" = ok ]; then
    plant "$p.fmt.wax" wax "$p.plant.wax"
    local nw; nw="$(count_sent "$p.plant.wax")"
    check_conv "$seed" "$p.plant.wax" wax "$nw" wax "$p"
    check_conv "$seed" "$p.plant.wax" wax "$nw" wat "$p"
  fi
  [ -n "$OUT" ] && printf '%s' "$OUT" >"$RESULTS/$2"
  printf '.' >&2
}
export -f check_seed count_sent ids_of plant check_conv
export WAX WASM_TOOLS TIMEOUT WT_FEATURES RESULTS PLANT

# Curated seeds: spec-source WAT, minus the (@if) conditionals (they need -D).
mapfile -t SEED_FILES < <(grep -L '@if' "$SEEDS"/*.wat 2>/dev/null | sort)
NSEEDS=${#SEED_FILES[@]}
[ "$NSEEDS" -gt 0 ] || { echo "no seeds at $SEEDS/*.wat" >&2; exit 2; }

echo "planting comments in $NSEEDS modules across $JOBS jobs (frozen wax)..." >&2
idx=0
for seed in "${SEED_FILES[@]}"; do
  ( check_seed "$seed" "$idx" ) &
  idx=$((idx + 1))
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== comment-preserve report ==================="
echo "modules:  $NSEEDS"
echo "findings (dropped comments / broken conversions): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
grep -q $'\tHIGH\t' "$REPORT" && exit 1
exit 0
