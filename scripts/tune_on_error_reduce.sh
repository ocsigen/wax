#!/usr/bin/env bash
# tune_on_error_reduce.sh — %on_error_reduce annotation tuner (ERROR-MESSAGES.md step 8)
#
# WHAT IT IS
#   A read-only advisor that automates, at the level the evidence supports, the
#   hand A/B work of step 4b: it RECOMMENDS single %on_error_reduce moves; it
#   NEVER applies them, and it NEVER touches the source tree (every trial runs
#   against a *copy* of the grammar in a throwaway scratch dir). It is not wired
#   into `dune runtest` — the three promoted goldens already guard the committed
#   state; this tool explores candidate changes when the grammar has grown.
#
#   Run it on demand, review its output by eye, and apply any accepted move by
#   editing the real `%on_error_reduce` line and going through the normal golden
#   promote loop. Single-move scores DO NOT COMPOSE (the 4b
#   list(index)/list(elemexpr) interaction proved it): any applied *set* needs a
#   fresh combined re-check.
#
# THE NO-OVERRIDES TRIAL CONSTRAINT (important — read before changing this file)
#   A trial that changes the annotation list can merge/renumber automaton states,
#   which makes `menhir --list-errors` re-pick its representative sentence per
#   state. The step-5 `.overrides` files are keyed by sentence, so a re-picked
#   sentence can fail the generator's hard rot check (`check_override_rot`) and
#   kill the trial. Therefore EVERY invocation here runs the generator WITHOUT
#   `-overrides`, and the baseline is computed the same no-overrides way. The
#   counters then include the 52 would-be-overridden states uniformly on BOTH
#   sides of every comparison, so the deltas stay meaningful. (Consequence: the
#   "over 5" fallback counter shows the raw pre-override figure — 18 wasm / 34
#   wax — not the post-override 0; that is expected and correct for A/B deltas.)
#
# THE PIPELINE PER TRIAL (all direct invocations — no dune, no tree mutation)
#   menhir COPY.mly --list-errors                         > trial.messages
#   menhir COPY.mly --cmly --no-code-generation --base X  > X.cmly
#   generate_error_messages.exe -cmly X.cmly \
#       {-stats | -census | -generate-messages -no-comments} trial.messages
#   Candidate ADDITIONS are enumerated from `menhir COPY.mly --dump` (the LHS of
#   every `reduce production N ->` line = the nonterminals reducible somewhere in
#   the automaton, i.e. every nonterminal a %on_error_reduce move could act on).
#
# THE THREE PARTS (see ERROR-MESSAGES.md §8)
#   1. DEAD SWEEP    — remove each current annotation; if all three goldens
#                      (stats, census, sorted-projection) diff zero, it is dead.
#   2. ADVISOR       — for each single move (remove a current annotation, or add
#                      a reducible nonterminal not yet annotated) compute the
#                      stats-vector delta and classify it; emit a full block
#                      (vector delta + census diff) for each strictly-improving
#                      move, ranked; summarise the rest.
#   3. CALIBRATION   — replay the 4b keep/remove log: every 4b-KEPT annotation is
#                      a removal candidate (removing it should be non-improving);
#                      every 4b-REMOVED annotation is an addition candidate
#                      (re-adding it should be non-improving). Report the
#                      agreement fraction and every disagreement.
#
# CLASSIFICATION (the scoring model, matching 4b's decision rule)
#   The stats vector: over5 (fallbacks, ↓good), empty-fallback (↓good),
#   delimiter-hints (↑good), jargon (0), unsound (0), missed-hints (0),
#   uncovered entries+tokens (↓good), spurious-reduction template count (↓good —
#   4b's core "reveal the element directly, don't hedge" win), cascade≥4 (↓mild
#   good), entries/with-list (informational — state merge/un-merge).
#
#   HARMFUL (hard constraints — any one ⇒ non-improving): a new fallback
#     (Δover5>0 or Δempty>0), a lost delimiter hint (Δhints<0), new jargon /
#     unsound / missed hint (Δ>0), or more hidden actions (Δuncovered>0).
#   IMPROVING: not harmful AND at least one of: fewer hedges (Δtemplate<0),
#     fewer hidden actions (Δuncovered<0), or a removed fallback (Δover5<0).
#     (Reducing the hedge count is the 4b list-annotation win; reducing uncovered
#     is the step-4 add win; both are captured.)
#   DEAD: a removal whose three goldens all diff zero (report for deletion).
#   MIXED: not harmful, not improving, but carries a genuine good signal bundled
#     with a bad one the vector cannot net out — Δhints>0 or Δcascade<0 arriving
#     together with Δtemplate>0 (a hint gained but only by re-introducing a hedge
#     that hides the element continuation — exactly the step-4-add vs 4b-remove
#     tension §8 warns the counters cannot fully resolve). Flagged for a human.
#   NEUTRAL: everything else (no quality movement; e.g. a pure count merge).
#
# USAGE
#   scripts/tune_on_error_reduce.sh [wasm|wax|both] [dead|advise|calibrate|all]
#   Defaults: both all.  Output is a human/agent review report on stdout; a full
#   sweep over both grammars is a few minutes. Nothing is written outside the
#   scratch dir, which is removed on exit.
set -euo pipefail

MODE_G="${1:-both}"
MODE_P="${2:-all}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$REPO/_build/default/scripts/generate_error_messages.exe"
MENHIR="$(command -v menhir || true)"

if [ -z "$MENHIR" ]; then
  echo "error: menhir not on PATH (try: opam exec --switch=5.4.0 -- $0 ...)" >&2
  exit 1
fi
if [ ! -x "$GEN" ]; then
  echo "generator exe missing; building it..." >&2
  (cd "$REPO" && dune build scripts/generate_error_messages.exe) \
    || { echo "error: could not build generate_error_messages.exe" >&2; exit 1; }
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/oer-tune.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# --- 4b keep/remove log (ERROR-MESSAGES.md §4b), by canonical menhir spelling ---
# KEPT = the current annotation lists (read from the grammar at run time), so the
# "removing a kept annotation is non-improving" half needs no hardcoding. Only the
# REMOVED set (gone from the tree) must be recorded here to be replayed as re-adds.
WASM_REMOVED_4B=(
  string_list 'list(STRING)' 'list(value_type)' 'list(field_type)' 'list(field)'
  'list(folded_instruction)' 'list(typedef)' 'list(const)' 'list(result_pat)'
  'nonempty_list(module_field)' 'list(index)'
)
WAX_REMOVED_4B=(
  labels_else statement_list optional_function_type structure_type result_type_
  expression_list structure argument_list
  'list(typedef)' 'list(data_item)'
  'separated_nonempty_list_trailing(COMMA,catch)'
  'loption(separated_nonempty_list_trailing(COMMA,catch))'
  'separated_nonempty_list_trailing(COMMA,condition)'
  'loption(separated_nonempty_list_trailing(COMMA,condition))'
  'separated_nonempty_list_trailing(COMMA,data_number)'
  'loption(separated_nonempty_list_trailing(COMMA,data_number))'
  'separated_nonempty_list_trailing(COMMA,data_run_item)'
  'loption(separated_nonempty_list_trailing(COMMA,data_run_item))'
  'separated_nonempty_list_trailing(COMMA,on_clause)'
  'loption(separated_nonempty_list_trailing(COMMA,on_clause))'
  'semi_list(legacy_catch)' 'semi_list(trycatch_arm)' 'semi_list(match_arm)'
  'semi_list(dispatch_arm)'
  block_type let_pattern
)

# getn KEY FILE — the trailing number of the unique "KEY: N" stats line.
getn() { grep -F "$1: " "$2" | head -1 | awk '{print $NF}'; }

# Fields captured from a stats file into shell vars prefixed $2.
load_stats() {
  local f="$1" p="$2"
  eval "${p}entries=$(getn 'entries' "$f")"
  eval "${p}withlist=$(getn 'with an expected list' "$f")"
  eval "${p}template=$(getn 'using the spurious-reduction template' "$f")"
  eval "${p}cascade=$(getn 'entries with cascade depth >= 4' "$f")"
  eval "${p}empty=$(getn 'generic fallback (empty expected list, not overridden)' "$f")"
  eval "${p}over5=$(getn 'generic fallback (expected list over 5, not overridden)' "$f")"
  eval "${p}hints=$(getn 'delimiter hints' "$f")"
  eval "${p}missed=$(getn 'missed delimiter hints (opener on stack, none matched)' "$f")"
  eval "${p}jargon=$(getn 'jargon-rendered tokens' "$f")"
  eval "${p}unsound=$(getn 'unsound claims' "$f")"
  eval "${p}uncov_e=$(getn 'entries with uncovered actions' "$f")"
  eval "${p}uncov_t=$(getn 'uncovered action tokens (total)' "$f")"
}

WORK=""      # per-grammar scratch working dir
BASE_STATS=""; BASE_CENSUS=""; BASE_ACTUAL=""

# run_pipeline MLY OUTPREFIX — list-errors + cmly + the three generator outputs.
# Sets nothing; writes $OUTPREFIX.{stats,census,actual}. Returns non-zero on a
# menhir/grammar failure (an invalid candidate name), so callers can skip it.
run_pipeline() {
  local mly="$1" out="$2" base
  base="$(basename "$out")"
  "$MENHIR" "$mly" --list-errors >"$out.messages" 2>/dev/null || return 1
  "$MENHIR" "$mly" --cmly --no-code-generation --base "$WORK/$base.cmlybase" \
    >/dev/null 2>&1 || true   # --cmly exits 1 (runs code backend) but writes the cmly
  local cmly="$WORK/$base.cmlybase.cmly"
  [ -f "$cmly" ] || return 1
  "$GEN" -cmly "$cmly" -stats "$out.messages" >"$out.stats" 2>/dev/null || return 1
  "$GEN" -cmly "$cmly" -census "$out.messages" >"$out.census" 2>/dev/null || return 1
  "$GEN" -cmly "$cmly" -generate-messages -no-comments "$out.messages" \
    >"$out.actual" 2>/dev/null || return 1
  return 0
}

# trial_grammar NEWLIST — write $WORK/trial.mly with the %on_error_reduce line
# replaced by "%on_error_reduce NEWLIST".
trial_grammar() {
  awk -v r="%on_error_reduce $1" \
    '/^%on_error_reduce /{print r; next} {print}' "$WORK/parser.mly" >"$WORK/trial.mly"
}

# classify BASEPREFIX TRIALPREFIX — echo one word:
#   HARMFUL IMPROVING DEAD MIXED NEUTRAL  (plus a short reason after a tab)
# reads $b* (baseline) and $t* (trial) already loaded.
classify() {
  local d_over5=$((t_over5 - b_over5)) d_empty=$((t_empty - b_empty))
  local d_hints=$((t_hints - b_hints)) d_jargon=$((t_jargon - b_jargon))
  local d_unsound=$((t_unsound - b_unsound)) d_missed=$((t_missed - b_missed))
  local d_uncov_e=$((t_uncov_e - b_uncov_e)) d_uncov_t=$((t_uncov_t - b_uncov_t))
  local d_template=$((t_template - b_template)) d_cascade=$((t_cascade - b_cascade))
  local why=""
  # hard-harm constraints
  if [ $d_over5 -gt 0 ]; then echo -e "HARMFUL\t+$d_over5 over-5 fallback(s)"; return; fi
  if [ $d_empty -gt 0 ]; then echo -e "HARMFUL\t+$d_empty empty-list fallback(s)"; return; fi
  if [ $d_hints -lt 0 ]; then echo -e "HARMFUL\t${d_hints} delimiter hint(s)"; return; fi
  if [ $d_jargon -gt 0 ]; then echo -e "HARMFUL\t+$d_jargon jargon token(s)"; return; fi
  if [ $d_unsound -gt 0 ]; then echo -e "HARMFUL\t+$d_unsound unsound claim(s)"; return; fi
  if [ $d_missed -gt 0 ]; then echo -e "HARMFUL\t+$d_missed missed hint(s)"; return; fi
  if [ $d_uncov_e -gt 0 ] || [ $d_uncov_t -gt 0 ]; then
    echo -e "HARMFUL\t+$d_uncov_e uncovered entries / +$d_uncov_t tokens"; return; fi
  # improving signals (no harm present)
  [ $d_template -lt 0 ] && why="$why template$d_template"
  [ $d_uncov_e -lt 0 ] && why="$why uncov_e$d_uncov_e"
  [ $d_uncov_t -lt 0 ] && why="$why uncov_t$d_uncov_t"
  [ $d_over5 -lt 0 ] && why="$why over5$d_over5"
  if [ -n "$why" ]; then echo -e "IMPROVING\t$why"; return; fi
  # dead: zero diff on all three goldens
  if diff -q "$BASE_STATS" "$1.stats" >/dev/null 2>&1 \
     && diff -q "$BASE_CENSUS" "$1.census" >/dev/null 2>&1 \
     && diff -q "$BASE_ACTUAL" "$1.actual" >/dev/null 2>&1; then
    echo -e "DEAD\tzero diff on all three goldens"; return
  fi
  # mixed: a good signal bundled with a hedge increase the vector cannot net out
  if { [ $d_hints -gt 0 ] || [ $d_cascade -lt 0 ]; } && [ $d_template -gt 0 ]; then
    echo -e "MIXED\t+$d_hints hints / cascade$d_cascade but +$d_template hedge(s)"; return
  fi
  echo -e "NEUTRAL\tno quality movement (template$d_template hints+$d_hints cascade$d_cascade)"
}

# vector_delta_line — a compact one-line vector delta for the report.
vector_delta_line() {
  printf "    Δ over5=%+d empty=%+d hints=%+d template=%+d cascade=%+d uncov=%+d/%+d jargon=%+d unsound=%+d | entries %d→%d withlist %d→%d\n" \
    $((t_over5-b_over5)) $((t_empty-b_empty)) $((t_hints-b_hints)) \
    $((t_template-b_template)) $((t_cascade-b_cascade)) \
    $((t_uncov_e-b_uncov_e)) $((t_uncov_t-b_uncov_t)) \
    $((t_jargon-b_jargon)) $((t_unsound-b_unsound)) \
    "$b_entries" "$t_entries" "$b_withlist" "$t_withlist"
}

# setup_grammar wasm|wax — copy the real grammar, compute the no-overrides
# baseline, and populate CUR_ANNOTS + ADD_CANDIDATES.
CUR_ANNOTS=(); ADD_CANDIDATES=()
setup_grammar() {
  local g="$1"
  WORK="$SCRATCH/$g"; mkdir -p "$WORK"
  cp "$REPO/src/lib-$g/parser.mly" "$WORK/parser.mly"
  local line
  line="$(grep '^%on_error_reduce ' "$WORK/parser.mly" | sed 's/^%on_error_reduce //')"
  # shellcheck disable=SC2206
  CUR_ANNOTS=($line)
  BASE_STATS="$WORK/base.stats"; BASE_CENSUS="$WORK/base.census"; BASE_ACTUAL="$WORK/base.actual"
  run_pipeline "$WORK/parser.mly" "$WORK/base" || { echo "baseline pipeline failed for $g" >&2; exit 1; }
  # addition candidates: LHS of every reduce production in the automaton, minus
  # the current annotations and menhir-internal __anonymous symbols.
  "$MENHIR" "$WORK/parser.mly" --dump --base "$WORK/pdump" >/dev/null 2>&1 || true
  local all_reducible cur_set
  cur_set="$(printf '%s\n' "${CUR_ANNOTS[@]}" | sort -u)"
  all_reducible="$(grep -oE 'reduce production [^ ]+ ->' "$WORK/pdump.automaton" \
    | sed -E 's/reduce production (.*) ->/\1/' | grep -v '__anonymous' | sort -u)"
  ADD_CANDIDATES=()
  while IFS= read -r nt; do
    [ -z "$nt" ] && continue
    if grep -qxF "$nt" <<<"$cur_set"; then continue; fi
    ADD_CANDIDATES+=("$nt")
  done <<<"$all_reducible"
}

# build the trial for a move and load its vectors; echoes the trial prefix.
# move_grammar remove|add NT
move_grammar() {
  local op="$1" nt="$2" newlist
  if [ "$op" = remove ]; then
    newlist="$(printf '%s\n' "${CUR_ANNOTS[@]}" | grep -vxF "$nt" | tr '\n' ' ' | sed 's/ $//')"
  else
    newlist="$(printf '%s ' "${CUR_ANNOTS[@]}")$nt"
  fi
  trial_grammar "$newlist"
}

# ------------------------------- report parts -------------------------------

run_dead_sweep() {
  echo "### DEAD SWEEP ($1) — remove each current annotation, expect a diff"
  local dead=0
  for nt in "${CUR_ANNOTS[@]}"; do
    move_grammar remove "$nt"
    if run_pipeline "$WORK/trial.mly" "$WORK/trial"; then
      load_stats "$WORK/trial.stats" t_
      if diff -q "$BASE_STATS" "$WORK/trial.stats" >/dev/null \
         && diff -q "$BASE_CENSUS" "$WORK/trial.census" >/dev/null \
         && diff -q "$BASE_ACTUAL" "$WORK/trial.actual" >/dev/null; then
        echo "  DEAD: $nt (zero diff on all three goldens — report for deletion)"
        dead=$((dead+1))
      fi
    else
      echo "  (skip: removing $nt made menhir fail)"
    fi
  done
  echo "  dead annotations found: $dead"
  echo
}

run_advisor() {
  echo "### ADVISOR ($1) — single-move ranking (${#CUR_ANNOTS[@]} removals, ${#ADD_CANDIDATES[@]} additions)"
  load_stats "$BASE_STATS" b_
  local improving=() mixed=() harmful=0 neutral=0 dead=0 skipped=0
  local move nt verdict cls reason
  do_move() {
    local op="$1" nt="$2"
    move_grammar "$op" "$nt"
    if ! run_pipeline "$WORK/trial.mly" "$WORK/trial"; then skipped=$((skipped+1)); return; fi
    load_stats "$WORK/trial.stats" t_
    verdict="$(classify "$WORK/trial" "$WORK/trial")"
    cls="${verdict%%$'\t'*}"; reason="${verdict#*$'\t'}"
    case "$cls" in
      IMPROVING) improving+=("$op $nt"$'\t'"$reason"$'\t'"$(vector_delta_line)"$'\t'"$(diff "$BASE_CENSUS" "$WORK/trial.census" || true)");;
      MIXED)     mixed+=("$op $nt ($reason)");;
      HARMFUL)   harmful=$((harmful+1));;
      DEAD)      dead=$((dead+1));;
      NEUTRAL)   neutral=$((neutral+1));;
    esac
  }
  for nt in "${CUR_ANNOTS[@]}";   do do_move remove "$nt"; done
  for nt in "${ADD_CANDIDATES[@]}"; do do_move add "$nt"; done

  echo "  summary: improving=${#improving[@]} mixed=${#mixed[@]} harmful=$harmful dead/no-op=$dead neutral=$neutral skipped=$skipped"
  echo
  if [ ${#improving[@]} -eq 0 ]; then
    echo "  No strictly-improving single move (expected right after a 4b prune)."
  else
    echo "  IMPROVING MOVES (review each — scores do not compose):"
    for e in "${improving[@]}"; do
      IFS=$'\t' read -r mv rsn vec cen <<<"$e"
      echo "  ---- $mv  [$rsn]"
      echo "$vec"
      echo "    census diff:"; echo "$cen" | sed 's/^/      /'
    done
  fi
  echo
  if [ ${#mixed[@]} -gt 0 ]; then
    echo "  MIXED — needs a human eye (a hint/cascade gain bundled with a new hedge):"
    for m in "${mixed[@]}"; do echo "    $m"; done
    echo
  fi
}

run_calibration() {
  local g="$1"; shift
  local removed=("$@")
  echo "### CALIBRATION ($g) — replay the 4b keep/remove log"
  load_stats "$BASE_STATS" b_
  local agree=0 total=0 disagreements=()
  # KEPT half: the current list. Removing each should be NON-improving.
  for nt in "${CUR_ANNOTS[@]}"; do
    move_grammar remove "$nt"
    run_pipeline "$WORK/trial.mly" "$WORK/trial" || { continue; }
    load_stats "$WORK/trial.stats" t_
    local v; v="$(classify "$WORK/trial" "$WORK/trial")"; v="${v%%$'\t'*}"
    total=$((total+1))
    if [ "$v" = IMPROVING ]; then
      disagreements+=("KEPT-but-removal-scored-IMPROVING: $nt")
    else agree=$((agree+1)); fi
  done
  # REMOVED half: re-adding each should be NON-improving.
  for nt in "${removed[@]}"; do
    move_grammar add "$nt"
    if ! run_pipeline "$WORK/trial.mly" "$WORK/trial"; then
      disagreements+=("REMOVED-unmatched(menhir rejected): $nt"); continue
    fi
    load_stats "$WORK/trial.stats" t_
    local v; v="$(classify "$WORK/trial" "$WORK/trial")"; v="${v%%$'\t'*}"
    total=$((total+1))
    if [ "$v" = IMPROVING ]; then
      disagreements+=("REMOVED-but-re-add-scored-IMPROVING: $nt")
    else agree=$((agree+1)); fi
  done
  echo "  agreement: $agree / $total"
  if [ ${#disagreements[@]} -gt 0 ]; then
    echo "  disagreements:"
    for d in "${disagreements[@]}"; do echo "    $d"; done
  fi
  echo
}

process_grammar() {
  local g="$1"
  echo "==================== GRAMMAR: $g ===================="
  setup_grammar "$g"
  echo "current %on_error_reduce (${#CUR_ANNOTS[@]}): ${CUR_ANNOTS[*]}"
  echo "reducible addition candidates: ${#ADD_CANDIDATES[@]}"
  echo
  local removed_arr=()
  if [ "$g" = wasm ]; then removed_arr=("${WASM_REMOVED_4B[@]}"); else removed_arr=("${WAX_REMOVED_4B[@]}"); fi
  case "$MODE_P" in
    dead) run_dead_sweep "$g";;
    advise) run_advisor "$g";;
    calibrate) run_calibration "$g" "${removed_arr[@]}";;
    all) run_dead_sweep "$g"; run_advisor "$g"; run_calibration "$g" "${removed_arr[@]}";;
    *) echo "unknown part '$MODE_P'" >&2; exit 1;;
  esac
}

START=$(date +%s)
case "$MODE_G" in
  wasm) process_grammar wasm;;
  wax) process_grammar wax;;
  both) process_grammar wasm; process_grammar wax;;
  *) echo "usage: $0 [wasm|wax|both] [dead|advise|calibrate|all]" >&2; exit 1;;
esac
echo "full sweep runtime: $(( $(date +%s) - START ))s"
