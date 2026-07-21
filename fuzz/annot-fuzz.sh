#!/usr/bin/env bash
#
# annot-fuzz.sh
#
# A guess-and-filter mutator that ADDS type annotations to valid Wax and asserts
# the round-trip survives. The invariant it guards:
#
#   Dropping a type annotation on the wasm->wax decompile is only SOUND if
#   re-inference recovers the same type. So for any Wax the checker accepts,
#   ADDING an annotation the checker also accepts must never break the
#   round-trip. If `wax -> wasm -> wax` then fails to recompile (or the binaries
#   fail to validate), the wasm->wax simplify pass dropped a LOAD-BEARING
#   annotation — the exact bug class documented in IF-KEEP-BOOL.md.
#
# This is the one oracle that reaches that class. The decompiler-seeded corpus
# cannot: a decompiled seed is already a fixed point of the very simplify pass
# under test, so its annotations were dropped when it was produced. wasm-smith
# never emits code that decompiles to an annotated `let x: T = if ...` binding.
# The silent flavors (a dropped annotation that still recompiles but retypes,
# e.g. `ref.null $t` -> `ref.null none`, or an unused i64 local -> i32) are
# invisible to every validity oracle. Here we ADD the annotation ourselves,
# filter to the ones the checker accepts, and demand the round-trip hold.
#
# Mechanics (deterministic given SEED):
#   * Seeds: built-in seeds embedded below (wax forms of the two live repros of
#     the bug family — seed-if-flexible-i64, seed-if-flexible-arith-i64,
#     seed-if-nested-null — plus infer.wax-like fixed-case controls), then, when
#     present, modules from fuzz/corpus-wax/valid for breadth (authorial-* seeds
#     included — the hand-written ones carry annotations the decompiled ones do
#     not).
#   * Mutants: insert `: T` at unannotated binding sites (`let <name> =`, `_ =`)
#     and `=> T` at `if`/`do` result positions, one insertion per mutant.
#     Candidate types T are the primitives (i32/i64/f32/f64), abstract reference
#     forms (&?any/&any/&?extern/&?eq/&?func/&?none/&?i31/&?struct) and, per type
#     name declared in the module, &name / &?name. No cleverness — we generate
#     candidates then FILTER: only mutants `wax check` accepts survive.
#   * Round-trip: for each surviving mutant, `wax -> wasm` (rt1, validated),
#     `wasm -> wax` (decompile), `wax -> wasm` (rt2, validated). A failure at the
#     decompile-recompile step, or a wasm-tools rejection, is a HIGH ROUNDTRIP
#     finding — a dropped load-bearing annotation.
#
# Built-in seeds are enumerated exhaustively (all sites x all types) so the guard
# has teeth with no corpus built; corpus candidates are sampled deterministically
# down to a COUNT budget by a hash of SEED + the candidate identity. wasm-tools
# is used for validation when available, but the core failure (rt2 does not
# recompile) is detected with wax alone, so the guard runs without it.
#
#   ROUNDTRIP  — an accepted annotation broke the round-trip. HIGH.
#   EMIT       — an accepted mutant did not even compile to wasm. HIGH.
# Exits non-zero on any HIGH finding. Findings (the failing mutants) are saved
# under fuzz/annot-findings/ with a runnable repro.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${COUNT:-200}"                         # corpus mutants round-tripped (budget)
CORPUS_SEEDS="${CORPUS_SEEDS:-300}"           # corpus seeds sampled for candidates
CORPUS="${CORPUS:-$ROOT/fuzz/corpus-wax/valid}"
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
FIND="$ROOT/fuzz/annot-findings"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"
announce_seed fuzz/annot-fuzz.sh

have_wt() { command -v "$WASM_TOOLS" >/dev/null 2>&1; }

# ---- Built-in seeds: the live repros and their controls. ----
# Written UNANNOTATED and thus ill-typed as-is; the mutator's job is to add the
# annotation that rescues them, which — for a load-bearing annotation — the
# decompile then drops, breaking the round-trip.
BASE="$RESULTS/base"; mkdir -p "$BASE"
seed() { printf '%s\n' "$2" >"$BASE/$1.wax"; }

# Repro A (flexible literal): `let x: i64 = if c { 1 } else { 2 }`. Unannotated,
# x re-infers i32 and the i64-returning tail rejects. Adding `: i64` type-checks
# but the decompile drops it, so `x;` re-infers i32 and rt2 fails.
seed seed-if-flexible-i64 'fn f(y: i32) -> i64 {
    let x = if y { 1; } else { 2; };
    x;
}'

# Repro A variant (flexible arithmetic tail): the branch value is `1 + 2`, whose
# flexible type is produced by inference over the operands — no tail desc can
# recognise it. Same failure.
seed seed-if-flexible-arith-i64 'fn f(y: i32) -> i64 {
    let x = if y { 1 + 2; } else { 3; };
    x;
}'

# Repro B (nested null): every arm is a bare `null` one level deep; adding
# `: &?t` type-checks but the decompile drops it, x re-infers &?none, and the
# following `x = z` (z: &?t) rejects.
seed seed-if-nested-null 'type t = [i8];
fn f(y: i32, z: &?t) {
    let x =
        if y {
            if y { null; } else { null; }
        } else {
            null;
        };
    x = z;
}'

# Control (infer.wax-like, already fixed by commit 1e203ba0bd): an un-named array
# literal in a branch keeps its annotation correctly, so adding `: &?t` must
# round-trip cleanly (a NEGATIVE seed proving the guard is not blanket-failing).
seed seed-infer-array 'type t = [i8];
fn f(y: i32, z: &?t) {
    let x =
        if y {
            if y { [1]; } else { [2]; }
        } else {
            z;
        };
}'

# ---- Candidate generation. ----
# Unannotated binding sites and `if`/`do` result positions on which to insert.
list_sites() {
  awk '
    { l = $0 }
    l ~ /^[[:space:]]*let[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { print NR "\tlet" }
    l ~ /^[[:space:]]*_[[:space:]]*=/                                     { print NR "\tdrop" }
    (l ~ /(^|[^A-Za-z0-9_])if[[:space:]].*\{[[:space:]]*$/) && (l !~ /=>/) { print NR "\tif" }
    (l ~ /(^|[^A-Za-z0-9_])do[[:space:]]*\{/) && (l !~ /=>/)              { print NR "\tdo" }
  ' "$1"
}

# Candidate types: primitives, abstract reference forms, and a ref to every type
# name the module declares (both null and non-null).
list_types() {
  local base="i32,i64,f32,f64,&?any,&any,&?extern,&?eq,&?func,&?none,&?i31,&?struct" extra="" tn
  while IFS= read -r tn; do extra="$extra,&$tn,&?$tn"; done \
    < <(grep -oE '^type[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$1" | awk '{print $2}' | sort -u)
  printf '%s%s' "$base" "$extra"
}

# Produce one mutant on stdout: insert the annotation for (line, kind, type).
mutate() {
  awk -v L="$2" -v K="$3" -v T="$4" '
    NR == L {
      if (K == "let" && match($0, /^[[:space:]]*let[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
        print substr($0, 1, RLENGTH) ": " T substr($0, RLENGTH + 1); next
      }
      if (K == "drop" && match($0, /^[[:space:]]*_/)) {
        print substr($0, 1, RLENGTH) ": " T substr($0, RLENGTH + 1); next
      }
      if (K == "if" && match($0, /\{[[:space:]]*$/)) {
        print substr($0, 1, RSTART - 1) "=> " T " " substr($0, RSTART); next
      }
      if (K == "do" && match($0, /do[[:space:]]*\{/)) {
        print substr($0, 1, RSTART - 1) "do => " T " {" substr($0, RSTART + RLENGTH); next
      }
    }
    { print }
  ' "$1"
}

# Expand one seed to `hash <TAB> seed <TAB> line <TAB> kind <TAB> type <TAB> name`
# candidate lines; the hash (0 for built-ins so they always sort first and are
# never cut) drives the deterministic corpus sample.
emit_candidates() {
  local seed="$1" name="$2" b="$3" types
  types="$(list_types "$seed")"
  list_sites "$seed" | awk -v F="$seed" -v NM="$name" -v B="$b" -v S="$SEED" -v TYPES="$types" '
    BEGIN { for (k = 0; k < 256; k++) ORD[sprintf("%c", k)] = k; nt = split(TYPES, TA, ",") }
    function h(s,   i, x) { x = 5381; for (i = 1; i <= length(s); i++) x = (x * 33 + ORD[substr(s, i, 1)]) % 2000000011; return x }
    { line = $1; kind = $2
      for (j = 1; j <= nt; j++) {
        t = TA[j]
        hv = (B == 1) ? 0 : h(S "|" NM "|" line "|" kind "|" t)
        printf "%d\t%s\t%s\t%s\t%s\t%s\n", hv, F, line, kind, t, NM
      }
    }'
}

# ---- Assemble the seed set and the selected candidate list. ----
BUILTIN_CAND="$RESULTS/builtin.tsv"; : >"$BUILTIN_CAND"
CORPUS_CAND="$RESULTS/corpus.tsv";   : >"$CORPUS_CAND"

for f in "$BASE"/*.wax; do
  emit_candidates "$f" "$(basename "${f%.wax}")" 1 >>"$BUILTIN_CAND"
done

if [ -d "$CORPUS" ]; then
  # Deterministic seed sample: order corpus files by a SEED-keyed hash, take the
  # first CORPUS_SEEDS, so which seeds are explored replays from SEED alone.
  while IFS= read -r f; do
    emit_candidates "$f" "$(basename "${f%.wax}")" 0 >>"$CORPUS_CAND"
  done < <(find "$CORPUS" -name '*.wax' | awk -v S="$SEED" '
             BEGIN { for (k = 0; k < 256; k++) ORD[sprintf("%c", k)] = k }
             function h(s,   i, x) { x = 5381; for (i = 1; i <= length(s); i++) x = (x * 33 + ORD[substr(s, i, 1)]) % 2000000011; return x }
             { printf "%d\t%s\n", h(S "|" $0), $0 }' \
           | sort -n | head -n "$CORPUS_SEEDS" | cut -f2-)
fi

SELECTED="$RESULTS/selected.tsv"
{
  cat "$BUILTIN_CAND"
  sort -n "$CORPUS_CAND" | head -n "$COUNT"
} >"$SELECTED"

nsel=$(wc -l <"$SELECTED")
nbuilt=$(wc -l <"$BUILTIN_CAND")
echo "annot-fuzz: $nsel candidate mutants ($nbuilt built-in, up to $COUNT corpus) across $JOBS jobs (frozen wax)" >&2

rm -rf "$FIND"; mkdir -p "$FIND"

# ---- Worker: mutate, filter by `wax check`, round-trip. ----
worker() {
  local id="$1" W="$RESULTS/w$1" out="$RESULTS/find.$1"
  mkdir -p "$W"; ERRLOG="$W/err"
  local mut="$W/mut.wax" rt1="$W/rt1.wasm" rtx="$W/rt.wax" rt2="$W/rt2.wasm"
  local h seed line kind typ name
  while IFS=$'\t' read -r h seed line kind typ name; do
    mutate "$seed" "$line" "$kind" "$typ" >"$mut"
    # A candidate that changed nothing (site the regex matched but mutate did
    # not touch) would just re-test the seed; skip it.
    diff -q "$mut" "$seed" >/dev/null 2>&1 && continue
    # Filter: only annotations the checker accepts are legitimate mutants.
    [ "$(classify_wax check "$mut")" = ok ] || { printf '.' >&2; continue; }

    local tag="$name-L$line-$kind-$(printf '%s' "$typ" | tr -c 'A-Za-z0-9' '_')"
    local repro
    if [ "$(classify_wax -i wax -f wasm "$mut" -o "$rt1")" != ok ]; then
      cp "$mut" "$FIND/$tag.wax"
      repro="$WAX -i wax -f wasm $FIND/$tag.wax"
      { finding EMIT HIGH "$name L$line/$kind :$typ" \
          "accepted mutant did not compile to wasm (adding ':$typ' at a $kind site)" \
          "$repro"; } >>"$out"
      printf 'E' >&2; continue
    fi
    if have_wt && ! wt_validate "$rt1"; then
      cp "$mut" "$FIND/$tag.wax"
      repro="$WAX -i wax -f wasm $FIND/$tag.wax -o rt1.wasm && wasm-tools validate --features all rt1.wasm"
      { finding EMIT HIGH "$name L$line/$kind :$typ" \
          "accepted mutant compiled to a binary wasm-tools rejects: $(head -1 "$rt1.err")" \
          "$repro"; } >>"$out"
      printf 'E' >&2; continue
    fi

    local rdc rc2
    rdc="$(classify_wax -i wasm -f wax "$rt1" -o "$rtx")"
    if [ "$rdc" != ok ]; then
      cp "$mut" "$FIND/$tag.wax"
      repro="$WAX -i wax -f wasm $FIND/$tag.wax -o rt1.wasm && $WAX -i wasm -f wax rt1.wasm"
      { finding ROUNDTRIP HIGH "$name L$line/$kind :$typ" \
          "mutant compiles but does not decompile back: $rdc" "$repro"; } >>"$out"
      printf 'F' >&2; continue
    fi
    rc2="$(classify_wax -i wax -f wasm "$rtx" -o "$rt2")"
    if [ "$rc2" != ok ]; then
      # The bug: the checker accepted the annotation, but the wasm->wax decompile
      # dropped it, so the decompiled Wax no longer recompiles.
      cp "$mut" "$FIND/$tag.wax"
      repro="$WAX -i wax -f wasm $FIND/$tag.wax -o rt1.wasm && $WAX -i wasm -f wax rt1.wasm -o rt.wax && $WAX -i wax -f wasm rt.wax"
      { finding ROUNDTRIP HIGH "$name L$line/$kind :$typ" \
          "adding ':$typ' at a $kind site type-checks but the decompile drops it; recompile fails ($rc2): $(grep -m1 -i error "$ERRLOG" || true)" \
          "$repro"; } >>"$out"
      printf 'F' >&2; continue
    fi
    if have_wt && ! wt_validate "$rt2"; then
      cp "$mut" "$FIND/$tag.wax"
      repro="$WAX -i wax -f wasm $FIND/$tag.wax -o rt1.wasm && $WAX -i wasm -f wax rt1.wasm -o rt.wax && $WAX -i wax -f wasm rt.wax -o rt2.wasm && wasm-tools validate --features all rt2.wasm"
      { finding ROUNDTRIP HIGH "$name L$line/$kind :$typ" \
          "round-trip binary rejected by wasm-tools: $(head -1 "$rt2.err")" "$repro"; } >>"$out"
      printf 'F' >&2; continue
    fi
    printf '.' >&2
  done <"$W/list"
  [ -s "$out" ] || rm -f "$out"
}

# Distribute the selected candidates round-robin across workers (assignment fixed
# by line order, so the run is deterministic regardless of scheduling).
for ((w = 0; w < JOBS; w++)); do mkdir -p "$RESULTS/w$w"; : >"$RESULTS/w$w/list"; done
awk -v J="$JOBS" -v D="$RESULTS" '{ print >> (D "/w" (NR % J) "/list") }' "$SELECTED"

for ((w = 0; w < JOBS; w++)); do
  [ -s "$RESULTS/w$w/list" ] && worker "$w" &
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/find.* 2>/dev/null | sort -u >"$REPORT"
high=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); high=${high:-0}
echo "=================== annot-fuzz report ==================="
echo "candidate mutants selected: $nsel"
echo "findings: $high HIGH (dropped load-bearing annotation / bad emission)"
if [ "$high" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
  echo
  echo "failing mutants saved under: $FIND"
  echo "full report with repros: $REPORT"
  cp "$REPORT" "${TMPDIR:-/tmp}/annot-fuzz-report.$$" 2>/dev/null \
    && echo "  -> ${TMPDIR:-/tmp}/annot-fuzz-report.$$"
fi
[ "$high" -gt 0 ] && exit 1
exit 0
