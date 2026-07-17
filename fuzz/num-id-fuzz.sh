#!/usr/bin/env bash
#
# num-id-fuzz.sh
#
# A metamorphic guard on how from_wasm resolves TYPE references written
# numerically vs symbolically. A `(type N)` / `(ref N)` and the `(type $name)` /
# `(ref $name)` that names index N are the SAME type, so flipping one reference
# from its name to its number is semantics-preserving: from_wasm must decompile
# the mutant to byte-identical Wax. When it does not, from_wasm treated the two
# forms of one type differently — the class of the `heaptype_eq` bug, where an
# inline signature referencing a declared type by number was not recognised as a
# duplicate of the same type referenced by name, so a spurious implicit type was
# minted and every later numeric `(type N)` reference shifted meaning.
#
# Whole-module flips would paper this over (all-numeric is as consistent as
# all-symbolic); the trigger is a MIXED module — one type referenced both ways.
# So wat-numid-mutate.js flips ONE reference at a time, and this driver
# enumerates every single-reference flip of every base module, asserting
# wax(base) == wax(flip_k(base)).
#
#   MISMATCH  — wax's Wax output differs between the symbolic and numeric form of
#               the same type (a minted phantom type / mis-resolution). HIGH.
#   MUTREJECT — the mutant (a numeric reference) is rejected though the base is
#               accepted: a numeric-reference resolution gap (e.g. a bare
#               `(type N)` the AST-construction path cannot resolve). REVIEW.
#   CRASH     — either conversion exits other than ok/rejected. HIGH.
#
# Bases are the built-in seeds (the mixed-reference shapes) plus, when a corpus
# exists, COUNT modules decompiled from it for breadth. Deterministic (no seed —
# the enumeration is exhaustive), parallel, wax-only (needs node for the mutator).
# Exits non-zero on any HIGH finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "num-id-fuzz: node not found (needed for the mutator)" >&2; exit 2; }

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
COUNT="${COUNT:-300}"        # corpus modules to decompile for breadth (if any)
CORPUS="${CORPUS:-$ROOT/fuzz/corpus/valid}"
MUT="$(dirname "${BASH_SOURCE[0]}")/wat-numid-mutate.js"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- Base set: built-in seeds (mixed-reference shapes) first. ----
BASE="$RESULTS/base"; mkdir -p "$BASE"
seed() { printf '%s\n' "$2" >"$BASE/$1.wat"; }

# The heaptype_eq case: an inline signature duplicates a declared func type. With
# every reference symbolic the inline sig dedups against $ft_s; flipping the
# reference in $a (or $ft_s) to numeric must not change that — else $g's numeric
# (type 2) shifts from f64 to (ref $s).
seed s01_dup_inline_sig '(module
  (type $s (struct))
  (type $ft_s (func (param (ref $s))))
  (func $a (param (ref $s)) unreachable)
  (func $b (param f64) unreachable)
  (func $g (type 2) unreachable))'

# A block type-use naming a function type, plus a call_indirect naming it: both
# are (type $name) references whose numeric form must resolve the same way.
seed s02_blocktype_typeuse '(module
  (type $vv (func))
  (type $ii (func (param i32) (result i32)))
  (table 1 funcref)
  (func $f (param i32) (result i32)
    (block $b (type $ii) (param i32) (result i32))
    (call_indirect (type $ii) (local.get 0) (i32.const 0)))
  (func $g (type $vv)))'

# Reference types threaded through struct/array fields and params — named type
# refs in several positions; a single flip must stay metamorphically stable.
seed s03_gc_reftypes '(module
  (type $node (struct (field (ref null $node)) (field i32)))
  (type $arr (array (mut (ref null $node))))
  (func $mk (param (ref $node)) (result (ref null $node)) (local.get 0))
  (func $len (param (ref $arr)) (result i32) (array.len (local.get 0))))'

# A rec group: the index of each member must line up with its name so a flipped
# self/cross reference still points at the right member.
seed s04_recgroup '(module
  (rec
    (type $t0 (struct (field (ref null $t1))))
    (type $t1 (struct (field (ref null $t0)))))
  (func $f (param (ref $t0)) (result (ref null $t1))
    (struct.get $t0 0 (local.get 0))))'

# ---- Corpus breadth: decompile up to COUNT valid .wasm to .wat (for the
# instruction/type variety the small seed set lacks). Skipped if absent. ----
if [ -d "$CORPUS" ]; then
  i=0
  while IFS= read -r f; do
    [ "$i" -ge "$COUNT" ] && break
    "$WAX" -f wat "$f" -o "$BASE/c$i.wat" 2>/dev/null || rm -f "$BASE/c$i.wat"
    i=$((i + 1))
  done < <(find "$CORPUS" -name '*.wasm' 2>/dev/null | sort)
fi

mapfile -t BASES < <(find "$BASE" -name '*.wat' | sort)
N=${#BASES[@]}

# Worker: for each base module, decompile it, then for every single named-type
# reference flip its numeric form and re-decompile; the two Wax outputs must be
# byte-identical.
worker() {
  local first="$1" last="$2" i base out="" k C
  local p="$RESULTS/w$first"
  local a="$p.a" b="$p.b" mut="$p.mut.wat"
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    base="${BASES[$i]}"
    # Numeric references are forbidden inside a conditional module, so a flip
    # there is legitimately rejected — skip rather than report noise.
    grep -q '(@if' "$base" && continue
    # The base must decompile; if not, it is not a valid starting point.
    if ! timeout -k 5 "$TIMEOUT" "$WAX" -i wat -f wax "$base" -o "$a" 2>"$ERRLOG"; then
      continue
    fi
    C="$(node "$MUT" "$base" --count 2>/dev/null)"; C="${C:-0}"
    for ((k = 0; k < C; k++)); do
      FLIP="$k" node "$MUT" "$base" >"$mut" 2>/dev/null || continue
      if ! timeout -k 5 "$TIMEOUT" "$WAX" -i wat -f wax "$mut" -o "$b" 2>"$p.errb"; then
        out+="$(finding NUMID REVIEW "$(basename "$base") flip $k" \
          "mutant (numeric ref) rejected though base accepted" "$(cat "$mut")")"$'\n'
        printf 'r' >&2; continue
      fi
      if ! diff -q "$a" "$b" >/dev/null 2>&1; then
        out+="$(finding NUMID HIGH "$(basename "$base") flip $k" \
          "wax output differs on symbolic vs numeric type reference" "$(cat "$mut")")"$'\n'
        printf 'F' >&2; continue
      fi
    done
    printf '.' >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "enumerating single-reference flips over $N base modules across $JOBS jobs (frozen wax)..." >&2
chunk=$(((N + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk))
  [ "$first" -ge "$N" ] && break
  last=$((first + chunk - 1)); [ "$last" -ge "$N" ] && last=$((N - 1))
  worker "$first" "$last" &
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
high=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); high=${high:-0}
review=$(grep -c $'\tREVIEW\t' "$REPORT" 2>/dev/null); review=${review:-0}
echo "=================== num-id report ==================="
echo "base modules: $N"
echo "findings: $high HIGH (mismatch/crash), $review REVIEW (mutant rejected)"
if [ "$((high + review))" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
  echo
  echo "full report with repros: $REPORT (kept)"; cp "$REPORT" "${TMPDIR:-/tmp}/num-id-report.$$" 2>/dev/null && echo "  -> ${TMPDIR:-/tmp}/num-id-report.$$"
fi
[ "$high" -gt 0 ] && exit 1
exit 0
