#!/usr/bin/env bash
#
# cond-fuzz.sh
#
# Fuzz the conditional-compilation subsystem (Cond_explore / Cond_specialize /
# cond_solver), which every other oracle leaves entirely dark: the corpus builder
# skips (@if) files and nothing else generates #[if]/-D, so that machinery only
# ever runs on empty input.
#
# It drives the real hand-written conditional seeds (test/wasmoo/wax/*.wax, whose
# #[if] conditions use a known handful of variables) under -D bindings, and pins
# Cond_explore against ground truth from the concrete configurations it abstracts:
#
#   * wax's path-sensitive validation ("wax check", no -D) accepts a conditional
#     module iff EVERY feasible configuration is well-typed;
#   * a full -D assignment selects ONE configuration and, being fully determined,
#     specialises the module completely so it can be emitted and validated.
#
# So over the assignments (the product of each used variable's edge values):
#   COND_UNSOUND    — "wax check" accepted the module, yet a concrete assignment
#                     is rejected: Cond_explore missed an ill-typed configuration.
#   COND_OVERREJECT — "wax check" rejected it, yet EVERY assignment is accepted
#                     (only trusted when the product was enumerated exhaustively):
#                     a path-sensitive false positive.
#   EMIT_UNSOUND    — a concrete assignment is accepted but the binary it emits is
#                     rejected by wasm-tools.
#   CRASH           — any specialise/convert under -D exits other than ok/rejected.
#
# Deterministic (edge values are fixed; if a variable product exceeds CAP the
# assignments are sub-sampled from the master SEED). Needs wasm-tools. Parallel
# across seeds; exits non-zero on any HIGH finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v "$WASM_TOOLS" >/dev/null 2>&1; then
  echo "cond-fuzz: wasm-tools not found (needed as the validity oracle)" >&2
  exit 2
fi

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
CAP="${CAP:-256}"          # max assignments per seed; larger products are sampled
SEEDS="${SEEDS:-$ROOT/test/wasmoo/wax}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Known conditional variables and their edge-value candidates. Booleans get
# true/false; [effects] the compared strings plus an unmatched one; [ocaml_version]
# a version ladder straddling every boundary the seeds compare against
# (5.1/5.2/5.3/5.5). A seed that uses a variable NOT listed here is skipped, so
# an assignment is never partial (which would leave an unemittable conditional).
declare -A VALS=(
  [wasi]="true false"
  [oxcaml]="true false"
  [cps]="true false"
  [jspi]="true false"
  [native]="true false"
  [effects]="jspi cps native other"
  [ocaml_version]="4.14.0 5.1.0 5.2.0 5.3.0 5.5.0 6.0.0"
)

# Every variable mentioned in a seed's #[if(...)] conditions.
vars_of() {
  grep -ohE "#\[if\([^]]*\)\]" "$1" 2>/dev/null \
    | grep -oE "[a-z_][a-z_0-9]*" | grep -vE "^(if|all|any|not)$" | sort -u
}

# Worker: fuzz one seed. Writes findings to $RESULTS/<n>.
fuzz_seed() {
  local seed="$1" n="$2" out=""
  local p="$RESULTS/w$n"
  ERRLOG="$p.err"
  local vars; mapfile -t vars < <(vars_of "$seed")
  [ ${#vars[@]} -eq 0 ] && { printf 's' >&2; return 0; }
  # Skip a seed using an unknown variable (an assignment would be partial).
  local v; for v in "${vars[@]}"; do
    [ -n "${VALS[$v]:-}" ] || { printf 'u' >&2; return 0; }
  done

  # All-configurations verdict (path-sensitive validation, no -D).
  local all_v; all_v="$(classify_wax check "$seed")"
  case "$all_v" in
    crash:*)
      out+="$(finding COND HIGH "$(basename "$seed")" "$all_v (wax check, all configs)" \
        "wax check $seed")"$'\n'
      printf F >&2 ;;
  esac

  # Cartesian product of the used variables' edge values -> "-D a=v -D b=w ...".
  local assigns=("") w cand next
  for v in "${vars[@]}"; do
    next=()
    for w in "${assigns[@]}"; do
      for cand in ${VALS[$v]}; do next+=("$w -D $v=$cand"); done
    done
    assigns=("${next[@]}")
  done
  local total=${#assigns[@]} exhaustive=1
  if [ "$total" -gt "$CAP" ]; then
    # Deterministic sub-sample: keep a stride derived from the master SEED.
    exhaustive=0
    local step=$(((total + CAP - 1) / CAP)) off=$((SEED % step)) i sampled=()
    for ((i = off; i < total; i += step)); do sampled+=("${assigns[$i]}"); done
    assigns=("${sampled[@]}")
  fi

  local any_reject=0 all_accept=1 a cv bin="$p.wasm"
  for a in "${assigns[@]}"; do
    cv="$(classify_wax $a --validate -f wasm "$seed" -o "$bin")"
    case "$cv" in
      crash:*)
        out+="$(finding COND HIGH "$(basename "$seed")" "$cv under$a" \
          "wax$a --validate -f wasm $seed")"$'\n'; printf F >&2; all_accept=0 ;;
      rejected) any_reject=1; all_accept=0 ;;
      ok)
        if ! wt_validate "$bin"; then
          out+="$(finding COND HIGH "$(basename "$seed")" \
            "EMIT_UNSOUND: accepted under$a but binary rejected: $(head -1 "$bin.err")" \
            "wax$a -f wasm $seed && wasm-tools validate $bin")"$'\n'; printf F >&2
        fi ;;
    esac
  done

  # Cross-check Cond_explore against the concrete configurations.
  if [ "$all_v" = ok ] && [ "$any_reject" = 1 ]; then
    out+="$(finding COND HIGH "$(basename "$seed")" \
      "COND_UNSOUND: wax check accepted, but a concrete -D config is rejected" \
      "wax check $seed  vs the -D configs")"$'\n'; printf F >&2
  elif [ "$all_v" = rejected ] && [ "$all_accept" = 1 ] && [ "$exhaustive" = 1 ]; then
    out+="$(finding COND HIGH "$(basename "$seed")" \
      "COND_OVERREJECT: wax check rejected, but every -D config is accepted" \
      "wax check $seed  vs the -D configs")"$'\n'; printf F >&2
  fi

  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$n"
  printf '.' >&2
}

mapfile -t SEED_FILES < <(grep -rl "#\[if(" "$SEEDS"/*.wax 2>/dev/null | sort)
NSEEDS=${#SEED_FILES[@]}
[ "$NSEEDS" -gt 0 ] || { echo "no conditional wax seeds in $SEEDS" >&2; exit 2; }

announce_seed "$(basename "$0")"
echo "fuzzing $NSEEDS conditional seeds (cap $CAP assignments each) across $JOBS jobs..." >&2
idx=0
for seed in "${SEED_FILES[@]}"; do
  # A ( ) subshell inherits the VALS array and the lib.sh helpers directly.
  ( fuzz_seed "$seed" "$idx" ) &
  idx=$((idx + 1))
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== cond-fuzz report ==================="
echo "conditional seeds: $NSEEDS"
echo "findings (crash / cond-unsound / over-reject / emit-unsound): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
