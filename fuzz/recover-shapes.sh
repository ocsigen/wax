#!/usr/bin/env bash
#
# recover-shapes.sh
#
# The RECOVERY dimension: the stream-reshaping passes on the wasm->wax path
# (recover_loops / recover_match / recover_trycatch / recover_dispatch,
# sink_let) rebuild `while`/`match`/`try`/`dispatch` surface from the lowered
# idioms [to_wasm] emits, and claim to be exact inverses (the two documented
# exceptions are gated behind --faithful). They are the least-tested reshaping
# code in lib-conversion (35-53% coverage in the 2026-08 audit, mostly their
# BAIL-OUT arms), because the fuzz corpora are wasm-smith output and
# decompiled modules — distributions that almost never contain the idioms the
# recoveries trigger on. A recovery bug therefore hides from every random leg.
#
# This guard feeds them their own food. SEEDS are the repo's cram-test .wax
# fixtures — the curated corpus of exactly the surface idioms — each lowered
# to unfolded wat (so the wat IS the idiom shape the recoveries were built to
# invert, and they fire by construction: calibration below). Each seed .wax
# and its lowered .wat go through fuzz/oracle.sh (crash / emitter-soundness /
# idempotence / round-trip / FAITHDRIFT / width legs — the full suite, the
# bottom-fuzz pattern). Then the NEAR-MISS leg, aimed at the bail-out arms: a
# deterministic budgeted subset of one-step structural mutations of the
# lowered wat — a nop inserted at a line, a line deleted, adjacent lines
# swapped, a branch depth bumped — each gated by `wax check` (the cross
# product over-generates; validity filters) and sent through oracle.sh. A
# recovery that fires on a shape it should decline, or declines a shape it
# should invert, surfaces as a ROUNDTRIP/FAITHDRIFT finding.
#
# Budgets: BASE seeds always run; MUTS (default 1200) mutants are selected
# evenly across the enumerated slots, deterministically (no seed needed —
# selection is by stride, not randomness). Raise MUTS for a nightly sweep.
#
# The BRANCH-STREAM leg exists because calibration proved oracle.sh blind to
# a whole polarity: a recovery that RETARGETS a branch (a while recovered over
# a break-to-outer) yields a module that still validates, and the static legs
# normalize label identity away. So each .wat candidate is also compared
# against its --faithful round trip as a stream of (mnemonic,
# branch-target-de-Bruijn-depth) — renaming invisible, retargeting a diff —
# with exactly two identities forgiven (a [nop], and an empty else arm), the
# ones the round trip normalizes by design.
#
# Calibration, the hard way. The guard's own first full run found a live bug
# (a nop-separated match-ladder binding mis-folded as a null arm — fixed in
# recover_match with the guard's finding as the cram pin). A PLANTED
# recover_loops bug (back-edge check accepting any br) then survived three
# runs in a row, each time exposing a guard defect instead: the br mutation
# bumped numeric depths where wax emits symbolic labels (a silent no-op); the
# stride selector picked nothing at stride 1 (NR % 1 == 1); and with both
# fixed, oracle.sh simply cannot see a retargeted branch — which is what
# forced the branch-stream leg. With it, the plant reports 3 BRDRIFT HIGH over
# the full 4030-mutant sweep and the clean binary reports 0. The smoke
# assertion below also fails the guard outright if the decompiled corpus stops
# containing while/match/try/dispatch surface (recoveries silently not firing
# would make the suite vacuous). Needs wasm-tools (oracle.sh); exits 2 to
# SKIP without it.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 2 ))}"
MUTS="${MUTS:-1200}"
ORACLE="$ROOT/fuzz/oracle.sh"
FINDINGS="$ROOT/fuzz/recover-findings"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"
export WAX WASM_TOOLS TIMEOUT WT_FEATURES

command -v "$WASM_TOOLS" >/dev/null 2>&1 || {
  echo "recover-shapes: wasm-tools not found (oracle.sh needs it)" >&2; exit 2; }

# ---- Seeds: every cram .wax fixture that compiles TO WASM flag-free. ----
# The wasm gate (not just `check`) is what excludes the conditional-compilation
# fixtures: an unresolved #[if] cannot reach a binary by design (`resolve with
# -D`), so oracle.sh's recompile legs would report the refusal as a finding —
# cond-fuzz.sh owns that surface with its own oracles.
SEEDS=()
while IFS= read -r f; do
  ERRLOG="$RESULTS/gate.err"
  [ "$(classify_wax "$f" -f wasm -o "$RESULTS/gate.wasm")" = ok ] && SEEDS+=("$f")
done < <(find "$ROOT/test/cram-tests" -name '*.wax' | sort)
[ "${#SEEDS[@]}" -gt 0 ] || { echo "recover-shapes: no seeds" >&2; exit 2; }

# ---- Lower each seed; smoke-check that the recoveries FIRE. ----
LOWERED="$RESULTS/lowered"
mkdir -p "$LOWERED"
n=0
for f in "${SEEDS[@]}"; do
  out="$LOWERED/$n.wat"
  ERRLOG="$RESULTS/gate.err"
  if [ "$(classify_wax "$f" -f wat --unfold -o "$out")" = ok ]; then
    cp "$f" "$LOWERED/$n.wax"
    n=$((n + 1))
  fi
done
NSEEDS=$n

recovered=0
for ((i = 0; i < NSEEDS; i++)); do
  w="$RESULTS/smoke.wax"
  ERRLOG="$RESULTS/gate.err"
  if [ "$(classify_wax -i wat -f wax "$LOWERED/$i.wat" -o "$w")" = ok ] \
     && grep -qE '(^|[^a-z])(while|match|try|dispatch) ' "$w"; then
    recovered=$((recovered + 1))
  fi
done
if [ "$recovered" -lt 10 ]; then
  echo "recover-shapes: SMOKE FAILURE — only $recovered/$NSEEDS decompiles show recovered surface (while/match/try/dispatch); the recoveries are not firing and this suite would be vacuous" >&2
  exit 1
fi

# ---- Enumerate mutation slots over the lowered wats. ----
# A slot is "file <TAB> kind <TAB> line"; kinds: nop (insert after), del,
# swap (with the next line), br+ / br- (bump a branch depth on that line).
SLOTS="$RESULTS/slots"
: >"$SLOTS"
for ((i = 0; i < NSEEDS; i++)); do
  awk -v f="$i" '
    { n = NR }
    /^[[:space:]]*[a-z]/ {
      print f "\tnop\t" NR; print f "\tdel\t" NR
      print f "\tswap\t" NR
    }
    /br(_if|_table|_on_[a-z_]+)?[ \t]+\$/ { print f "\tbr+\t" NR; print f "\tbr-\t" NR }
  ' "$LOWERED/$i.wat" >>"$SLOTS"
done
total=$(wc -l <"$SLOTS")
stride=$(((total + MUTS - 1) / MUTS)); [ "$stride" -lt 1 ] && stride=1
awk -v s="$stride" '(NR - 1) % s == 0' "$SLOTS" >"$RESULTS/picked"
NPICK=$(wc -l <"$RESULTS/picked")

apply_mutation() { # src kind line dst
  local src="$1" kind="$2" ln="$3" dst="$4"
  case "$kind" in
    nop) awk -v l="$ln" '{ print } NR == l { print "    nop" }' "$src" >"$dst" ;;
    del) awk -v l="$ln" 'NR != l' "$src" >"$dst" ;;
    swap) awk -v l="$ln" 'NR == l { hold = $0; next } NR == l + 1 { print; print hold; held = 1; next } { print } END { if (!held && hold != "") print hold }' "$src" >"$dst" ;;
    br+ | br-) # Retarget the line's branch to the NEIGHBOURING declared label
      # (wax-emitted wat uses symbolic labels, so a numeric-depth bump would be
      # a silent no-op — the first calibration's planted recover_loops bug
      # survived exactly because of that). Two passes: collect the block/loop
      # labels in declaration order, then swap the branch's target for the
      # previous/next one; an out-of-range or unchanged swap leaves the file
      # identical and the duplicate cell is wasted, not wrong.
      awk -v l="$ln" -v d="$([ "$kind" = br+ ] && echo 1 || echo -1)" '
        NR == FNR {
          if ($1 == "block" || $1 == "loop" || $1 == "if")
            if ($2 ~ /^\$/) lbls[++n] = $2
          next
        }
        FNR == l && match($0, /br(_if|_table|_on_[a-z_]+)?[ \t]+\$[A-Za-z0-9_.]+/) {
          tok = substr($0, RSTART, RLENGTH)
          tgt = tok; sub(/^[^$]*/, "", tgt)
          j = 0
          for (i = 1; i <= n; i++) if (lbls[i] == tgt) { j = i + d; break }
          if (j >= 1 && j <= n && lbls[j] != tgt) {
            pre = substr($0, 1, RSTART - 1)
            post = substr($0, RSTART + RLENGTH)
            op = tok; sub(/\$.*/, "", op)
            print pre op lbls[j] post; next
          }
        }
        { print }' "$src" "$src" >"$dst" ;;
  esac
}

# ---- The branch-stream leg. ----
# A recovery that RETARGETS a branch (recovering a while over a break-to-outer,
# say) produces a module that still validates, and oracle.sh's static legs
# normalize label identity away (renumbering is a documented residual) — the
# planted recover_loops calibration proved them blind to it. This leg compares
# the --faithful round trip as a stream of (mnemonic, branch-target-depth):
# labels are rewritten to de Bruijn depths on both sides, so renaming stays
# invisible but RETARGETING is a diff. Structure tokens (block/loop/if/else/
# end/function boundaries) are kept; parenthesized groups are stripped before
# reading targets so a type name in a [br_on_cast] immediate is not mistaken
# for one.
brstream() { # unfolded wat -> canonical stream on stdout
  awk '
    function strip_parens(s,  out, depth, i, c) {
      out = ""; depth = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(") depth++
        else if (c == ")") { if (depth > 0) depth-- }
        else if (depth == 0) out = out c
      }
      return out
    }
    /^[ 	]*\(func[ 	(]/ { delete lbl; top = 0; print "func"; next }
    {
      line = strip_parens($0)
      gsub(/^[ 	]+|[ 	]+$/, "", line)
      if (line == "") next
      n = split(line, tk, /[ 	]+/)
      op = tk[1]
      if (op == "block" || op == "loop" || op == "if") {
        top++; lbl[top] = (tk[2] ~ /^\$/) ? tk[2] : ("&anon" top)
        print op; next
      }
      if (op == "nop") next
      if (op == "else") { print "else"; next }
      if (op == "end") { if (top > 0) top--; print "end"; next }
      if (op ~ /^br(_if|_table|_on_[a-z_]+)?$/) {
        out = op
        for (i = 2; i <= n; i++) {
          if (tk[i] ~ /^\$/) {
            d = "?"
            for (j = top; j >= 1; j--) if (lbl[j] == tk[i]) { d = top - j; break }
            out = out "@" d
          } else if (tk[i] ~ /^[0-9]+$/ && out == op) out = out "@" tk[i]
        }
        print out; next
      }
      print op
    }' |
    # The two identities the round trip normalizes by design (and the
    # FAITHDRIFT leg already tolerates): a [nop] is effect-free wherever it
    # sits (dropped above), and an EMPTY else arm is the same instruction
    # structure as no else — collapse [else][end] to [end]. Nothing else is
    # forgiven.
    awk '{
      if (held == "else" && $0 == "end") { print "end"; held = "" }
      else { if (held != "") print held; held = $0 }
    } END { if (held != "") print held }'
}

# Compare candidate vs its --faithful round trip as branch streams; a diff is
# a HIGH finding oracle.sh cannot make. Prints nothing when clean.
brdrift() { # $1 = candidate .wat, $2 = scratch prefix
  local mid="$2.mid.wax" back="$2.back.wat" norm_a="$2.a" norm_b="$2.b"
  ERRLOG="$2.err"
  [ "$(classify_wax -i wat -f wax --faithful "$1" -o "$mid")" = ok ] || return 0
  [ "$(classify_wax -i wax -f wat --unfold "$mid" -o "$back")" = ok ] || return 0
  brstream <"$1" >"$norm_a"
  brstream <"$back" >"$norm_b"
  if ! cmp -s "$norm_a" "$norm_b"; then
    finding BRDRIFT HIGH "$1" \
      "branch/structure stream drifted across the --faithful round trip: $(diff "$norm_a" "$norm_b" | head -3 | tr '\n' ' ')" \
      "wax -i wat -f wax --faithful $1; relower and compare de-Bruijn branch streams"
  fi
  return 0
}

# ---- Drive oracle.sh over seeds, lowered wats, and the picked mutants. ----
# One job per line: "kind<TAB>file<TAB>line" (line 0 for the base jobs).
{
  for ((i = 0; i < NSEEDS; i++)); do
    printf 'base.wax\t%s\t0\n' "$i"
    printf 'base.wat\t%s\t0\n' "$i"
  done
  awk -F'\t' '{ print $2 "\t" $1 "\t" $3 }' "$RESULTS/picked"
} >"$RESULTS/all-jobs"
N=$(wc -l <"$RESULTS/all-jobs")

worker() {
  local first="$1" last="$2" i line out="$RESULTS/find.$1"
  : >"$out"
  ERRLOG="$RESULTS/w$1.err"
  for ((i = first; i <= last; i++)); do
    line="$(sed -n "${i}p" "$RESULTS/all-jobs")"
    [ -n "$line" ] || continue
    local kind file mline cand
    kind="${line%%	*}"
    local rest="${line#*	}"
    file="${rest%%	*}"
    mline="${rest#*	}"
    case "$kind" in
      base.wax) cand="$LOWERED/$file.wax" ;;
      base.wat) cand="$LOWERED/$file.wat" ;;
      *)
        cand="$RESULTS/m$1.wat"
        apply_mutation "$LOWERED/$file.wat" "$kind" "$mline" "$cand"
        if [ "$(classify_wax check "$cand")" != ok ]; then
          printf s >&2; continue
        fi
        ;;
    esac
    local found
    found="$(bash "$ORACLE" "$cand" unknown 2>/dev/null)"
    case "$cand" in
      *.wat) found="$found$(brdrift "$cand" "$RESULTS/bs$1")" ;;
    esac
    if [ -n "$found" ]; then
      printf '%s\n' "$found" >>"$out"
      # Save a HIGH finding's candidate so it is reproducible after the temp
      # dir is gone (the bottom-fuzz pattern; REVIEW noise is not kept).
      if printf '%s' "$found" | grep -q $'\tHIGH\t'; then
        mkdir -p "$FINDINGS"
        local tag="$kind-$file-$mline"
        cp "$cand" "$FINDINGS/$tag.${cand##*.}" 2>/dev/null
        printf '%s\n' "$found" >"$FINDINGS/$tag.findings"
      fi
    fi
    printf . >&2
  done
}

echo "recover-shapes: $NSEEDS seeds (of ${#SEEDS[@]} accepted fixtures), $NPICK/$total mutation slots, $N oracle runs across $JOBS jobs..." >&2
chunk=$(((N + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk + 1))
  [ "$first" -gt "$N" ] && break
  last=$((first + chunk - 1)); [ "$last" -gt "$N" ] && last=$N
  worker "$first" "$last" &
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/find.* >"$REPORT" 2>/dev/null
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "=================== recover-shapes report ==================="
echo "seeds: $NSEEDS  recovered-surface smoke: $recovered  mutants picked: $NPICK/$total"
echo "findings: $n  (HIGH: $h)"
if [ "$h" -gt 0 ]; then
  grep $'\tHIGH\t' "$REPORT"
  exit 1
fi
[ "$n" -gt 0 ] && { echo "(non-HIGH findings, informational:)"; head -20 "$REPORT"; }
exit 0
