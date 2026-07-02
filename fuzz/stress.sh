#!/usr/bin/env bash
#
# stress.sh
#
# Resource-limit stress test. Nothing else in the harness generates pathological
# inputs, yet OCaml's recursive parser, type checker, folding pass and printers
# make deep nesting a real [Stack_overflow] (SIGSEGV) risk, and wide constructs
# (huge label vectors, many locals/functions, long literals) a real blow-up
# risk. This grows each such dimension deterministically until wax stops
# accepting, and asserts the failure is always *graceful* — a clean rejection
# (123/128) or, tolerated, a timeout — never a crash (uncaught exception or
# signal). It also *pins the limits*: the summary reports how far each dimension
# scaled, so a regression that lowers a limit, or a newly-quadratic pass, shows.
#
# Severity model (finer than classify_wax's, because "slow" and "crashed" are
# different verdicts here):
#   ok        — accepted; keep doubling.
#   rejected  — a clean "no" (123/128): the intended graceful limit. Stop.
#   timeout   — exceeded the per-call timeout: a soft limit (usually a
#               superlinear pass — e.g. the wat printer is O(n^2) in block
#               nesting depth). Reported REVIEW; does NOT gate, since a big
#               enough input always times out — the point is to surface *where*.
#   crash     — signal / uncaught exception: the bug this hunts. HIGH; gates CI.
#
# Each dimension is swept by doubling from BASE to MAX, stopping at the first
# non-ok verdict (a larger input fails the same way), so the whole run is a few
# dozen wax invocations. Deterministic. Exits non-zero iff a CRASH was found.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE="${BASE:-512}"                       # first size tried
MAX="${MAX:-262144}"                      # stop probing beyond this (declare "no limit")
TIMEOUT="${STRESS_TIMEOUT:-${TIMEOUT}}"   # per-invocation; a longer run is a soft limit
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

G="$RESULTS/gen"        # scratch for the generated input
ERRLOG="$RESULTS/err"

# Repeat string $1 exactly $2 times with no separator (streaming, so O(n) and
# fast even for n in the hundred-thousands — no per-element shell loop).
rep() { yes "$1" | head -n "$2" | tr -d '\n'; }

# ---- Generators. Each writes a module of "size" N to stdout. ----
# Nesting (recursion depth): a chain of N nested constructs.
gen_fold() {  # (i32.add 0 (i32.add 0 (... 0))) — N deep
  printf '(module (func (result i32)\n'; rep '(i32.add (i32.const 0) ' "$1"
  printf '(i32.const 0)'; rep ')' "$1"; printf '))\n'
}
gen_block() {  # N nested (block ...) in one function
  printf '(module (func\n'; rep '(block ' "$1"; rep ')' "$1"; printf '))\n'
}
gen_wax_paren() {  # fn f() -> i32 { (((0))); } — N nested parenthesised exprs
  printf 'fn f() -> i32 { '; rep '(' "$1"; printf '0'; rep ')' "$1"; printf '; }\n'
}
# Width (vector / declaration count): one construct with N elements.
gen_brtable() {  # a br_table with N labels
  printf '(module (func (block (br_table '; rep '0 ' "$1"
  printf '(i32.const 0)))))\n'
}
gen_locals() { printf '(module (func\n'; rep '(local i32) ' "$1"; printf '))\n'; }
gen_funcs()  { printf '(module\n'; rep '(func) ' "$1"; printf ')\n'; }
gen_string() {  # a passive data segment with an N-byte string
  printf '(module (data "'; head -c "$1" /dev/zero | tr '\0' 'A'; printf '"))\n'
}

# Case table: "label | in_fmt | out_fmt | generator". A wasm in_fmt generator
# emits WAT which is compiled first, so the sweep then stresses the binary
# reader/writer rather than the text parser.
CASES=(
  "nest-fold|wat|wasm|gen_fold"            # parser + lowering
  "nest-fold-print|wat|wat|gen_fold"       # + wat printer / folding
  "nest-block|wat|wasm|gen_block"          # parser + lowering
  "nest-block-print|wat|wat|gen_block"     # + wat printer / folding
  "nest-block-codec|wasm|wasm|gen_block"   # binary reader + writer
  "nest-wax-paren|wax|wasm|gen_wax_paren"  # wax parser + typer
  "width-brtable|wat|wasm|gen_brtable"     # label-vector parsing
  "width-locals|wat|wasm|gen_locals"       # local declarations
  "width-funcs|wat|wasm|gen_funcs"         # many functions
  "width-string|wat|wasm|gen_string"       # long string literal
)

# Materialise case generator $3's input of size $2 into $G, in format $1.
# Returns non-zero (skip the size) if a wasm case will not pre-compile.
materialise() {
  if [ "$1" = wasm ]; then
    "$3" "$2" >"$G.wat" || return 1
    timeout "$TIMEOUT" "$WAX" -i wat -f wasm "$G.wat" -o "$G" 2>/dev/null
  else
    "$3" "$2" >"$G"
  fi
}

# Sweep one case. Prints its summary line to stdout; prints any FINDING to fd 3.
sweep_case() {
  local label="$1" in_fmt="$2" out_fmt="$3" gen="$4"
  local n="$BASE" last_ok=0 limit="no limit up to $MAX" v
  while [ "$n" -le "$MAX" ]; do
    if ! materialise "$in_fmt" "$n" "$gen"; then
      limit="uncompilable at $n (pre-compile failed)"; break
    fi
    v="$(classify_wax -i "$in_fmt" -f "$out_fmt" "$G" -o "$RESULTS/out")"
    case "$v" in
      ok)             last_ok="$n"; n=$((n * 2)) ;;
      rejected)       limit="clean reject at $n"; break ;;
      crash:timeout*) limit="TIMEOUT at $n (soft limit — likely superlinear)"
                      finding STRESS REVIEW "$label" "$limit" \
                        "$gen $n | wax -i $in_fmt -f $out_fmt" >&3; break ;;
      crash:*)        limit="CRASH at $n"
                      finding STRESS HIGH "$label" "${v#crash:} at size $n" \
                        "$gen $n | wax -i $in_fmt -f $out_fmt" >&3; break ;;
    esac
  done
  printf '  %-17s %-4s->%-4s accepted up to %-8s  %s\n' \
    "$label" "$in_fmt" "$out_fmt" "$last_ok" "$limit"
}

echo "stress-sweeping ${#CASES[@]} dimensions (base $BASE, max $MAX, ${TIMEOUT}s/call, frozen wax)..." >&2

FINDINGS="$RESULTS/findings"
REPORT="$RESULTS/report"
: >"$FINDINGS"
{
  for spec in "${CASES[@]}"; do
    IFS='|' read -r label in_fmt out_fmt gen <<<"$spec"
    sweep_case "$label" "$in_fmt" "$out_fmt" "$gen"
  done
} 3>"$FINDINGS" >"$REPORT"

echo "=================== stress report ==================="
cat "$REPORT"
nhigh=$(grep -c $'\tHIGH\t' "$FINDINGS" 2>/dev/null); nhigh=${nhigh:-0}
nrev=$(grep -c $'\tREVIEW\t' "$FINDINGS" 2>/dev/null); nrev=${nrev:-0}
echo
echo "crash findings (HIGH): $nhigh   soft-limit/timeouts (REVIEW): $nrev"
if [ "$nrev" -gt 0 ]; then echo; grep $'\tREVIEW\t' "$FINDINGS" | cut -f2,3,4,5 | sed 's/^/  /'; fi
if [ "$nhigh" -gt 0 ]; then
  echo; echo "CRASHES (must fix):"; grep $'\tHIGH\t' "$FINDINGS" | cut -f2,3,4,5,6 | sed 's/^/  /'
fi
echo
echo "note: TIMEOUT/soft-limit rows do not gate — a large enough input always"
echo "      times out; only a CRASH is a hard failure. Deterministic."
[ "$nhigh" -gt 0 ] && exit 1
exit 0
