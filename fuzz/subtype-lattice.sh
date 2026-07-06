#!/usr/bin/env bash
#
# subtype-lattice.sh
#
# A deterministic differential guard over the reference-type *subtype lattice* —
# the relation computed by [Types.heap_subtype] (types.ml). That function is the
# soundness core: it is consulted on every cast, br_on_cast, call_indirect, table
# and element check. A single wrong cell either rejects valid code or, far worse,
# accepts an unsound coercion. The confusion between a type's several integer
# "currencies" (source index, canonical store index, intra-group back-reference)
# and the exact-ref / rec-group canonical-identity rules are the home of a known
# V8 soundness bug, so they get first-class coverage here.
#
# The space is small and enumerable, so we enumerate it. For every ordered pair
# (ht1, ht2) of heap types drawn from a crafted universe — the fourteen abstract
# heap types plus concrete struct/array/func/cont types (with a subtype chain),
# their [exact] variants, and structurally-identical types placed in the same and
# in separate rec groups (the canonical-identity cases) — we build a module that
# *validates iff ht1 <: ht2*:
#
#     (module <shared type defs>
#       (func (param (ref ht1)) (result (ref ht2)) (local.get 0)))
#
# and compare wax's accept/reject verdict against two independent oracles:
# wasm-tools and the WebAssembly reference interpreter. All three must agree on
# every pair; a disagreement is a finding. wax being the odd one out is a real
# [heap_subtype] bug; the oracles disagreeing with each other (rare) is flagged
# for review.
#
# The reference interpreter (3.0.0) cannot parse [exact] refs and does not
# implement stack switching ([cont]). Rather than mistake an unsupported-feature
# rejection for a subtype rejection, we probe each heap type's *baseline*
# expressibility in the interpreter first (as fuzz/exec-ref.sh does) and abstain
# from its verdict on any pair whose endpoint it cannot express — those pairs are
# still checked wax-vs-wasm-tools.
#
# Each pair is its own set of validator invocations, fanned across cores
# (override JOBS). Exits non-zero if any pair disagrees, so it can gate CI.
# Deterministic.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS" || exit 1

have_ref=1
if [ ! -x "$REF" ]; then
  echo "note: reference interpreter not found at $REF; comparing wax vs wasm-tools only" >&2
  have_ref=0
fi

# Shared type definitions, identical in every generated module so that
# iso-recursive canonicalization is consistent across pairs. [$ida]/[$idb] and
# [$selfa]/[$selfb] are two structurally-identical pairs — one non-recursive, one
# self-referential — each defined in its own rec group, so they canonicalize to
# the *same* type: the exact-ref identity cases where a canonical-index bug bites.
#
# The reference interpreter (3.0.0) does not parse [cont], so a cont type
# definition alone makes it reject the whole module. We therefore keep [$co] out
# of the portable preamble and add it only for pairs that reference it (where the
# interpreter abstains regardless); dropping it only shifts store indices, which
# structural canonicalization is blind to, so identity relations are preserved.
PREAMBLE_PORTABLE='  (rec (type $st (sub (struct)))
       (type $st2 (sub $st (struct))))
  (type $ar (sub final (array (mut i32))))
  (type $fn (sub final (func)))
  (rec (type $selfa (struct (field (ref null $selfa)))))
  (rec (type $selfb (struct (field (ref null $selfb)))))
  (type $ida (struct (field i32)))
  (type $idb (struct (field i32)))'
PREAMBLE_CONT="$PREAMBLE_PORTABLE"'
  (type $co (sub final (cont $fn)))'

# Pick the smallest preamble that defines every type an ordered pair references.
preamble_for() {
  case "$1$2" in *'$co'*) printf '%s' "$PREAMBLE_CONT" ;; *) printf '%s' "$PREAMBLE_PORTABLE" ;; esac
}

# The heap-type expressions that go inside [(ref …)]. The abstract tops and
# bottoms, then the concrete types by index, then their [exact] variants.
HEAPTYPES=(
  func nofunc extern noextern exn noexn any eq i31 struct array none cont nocont
  '$st' '$st2' '$ar' '$fn' '$co' '$selfa' '$selfb' '$ida' '$idb'
  '(exact $st)' '(exact $st2)' '(exact $ar)' '(exact $fn)' '(exact $co)'
  '(exact $selfa)' '(exact $selfb)' '(exact $ida)' '(exact $idb)'
)
N=${#HEAPTYPES[@]}

gen_module() { # $1=param heaptype  $2=result heaptype
  printf '(module\n%s\n  (func (param (ref %s)) (result (ref %s)) (local.get 0)))\n' \
    "$(preamble_for "$1" "$2")" "$1" "$2"
}

# ACCEPT (A) / REJECT (R) verdicts. wax validates a wat->wasm conversion (a
# cross-format convert validates its text input); custom-descriptors is enabled
# so [exact] is accepted syntactically and its subtyping actually exercised.
wax_verdict() { "$WAX" -X custom-descriptors -i wat -f wasm "$1" -o /dev/null >/dev/null 2>&1 && echo A || echo R; }
wt_verdict()  { "$WASM_TOOLS" validate --features all "$1" >/dev/null 2>&1 && echo A || echo R; }
ref_verdict() { "$REF" "$1" >/dev/null 2>&1 && echo A || echo R; }

# Baseline: which heap types the reference interpreter can even express (a lone
# param of that ref type). Abstain from its verdict on pairs touching one it
# cannot. Indexed by position in HEAPTYPES.
REF_OK=()
if [ "$have_ref" = 1 ]; then
  probe="$RESULTS/probe.wat"
  for ((k = 0; k < N; k++)); do
    printf '(module\n%s\n  (func (param (ref %s))))\n' \
      "$(preamble_for "${HEAPTYPES[$k]}" "${HEAPTYPES[$k]}")" "${HEAPTYPES[$k]}" >"$probe"
    if "$REF" "$probe" >/dev/null 2>&1; then REF_OK[$k]=1; else REF_OK[$k]=0; fi
  done
fi

export WAX WASM_TOOLS REF RESULTS PREAMBLE_PORTABLE PREAMBLE_CONT have_ref
export -f gen_module wax_verdict wt_verdict ref_verdict preamble_for

# Worker: one ordered pair "i j". Writes a result line to a private file:
#   i j wax wt ref     (ref is '-' when abstaining)
worker() {
  local i="$1" j="$2" a="$3" b="$4" ref_ok_i="$5" ref_ok_j="$6"
  local m; m="$(mktemp -p "$RESULTS" pair.XXXXXX.wat)"
  gen_module "$a" "$b" >"$m"
  local wax wt ref='-'
  wax="$(wax_verdict "$m")"
  wt="$(wt_verdict "$m")"
  if [ "$have_ref" = 1 ] && [ "$ref_ok_i" = 1 ] && [ "$ref_ok_j" = 1 ]; then
    ref="$(ref_verdict "$m")"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$j" "$a<:$b" "$wax" "$wt" "$ref" \
    >"$(mktemp -p "$RESULTS" res.XXXXXX)"
  rm -f "$m"
}
export -f worker

echo "sweeping $((N * N)) ordered pairs over $N heap types (jobs=$JOBS)…" >&2
for ((i = 0; i < N; i++)); do
  for ((j = 0; j < N; j++)); do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$j" "${HEAPTYPES[$i]}" "${HEAPTYPES[$j]}" \
      "${REF_OK[$i]:-0}" "${REF_OK[$j]:-0}"
  done
done | xargs -P "$JOBS" -L1 bash -c 'worker "$@"' _

# Aggregate. A pair disagrees when the verdicts that were produced are not all
# equal. wax differing from an oracle is a wax bug (HIGH); the two oracles
# differing while wax matches one is an oracle discrepancy (REVIEW).
findings=0
accepts=0 ref_pairs=0
while IFS=$'\t' read -r i j rel wax wt ref; do
  [ "$wax" = A ] && accepts=$((accepts + 1))
  [ "$ref" != '-' ] && ref_pairs=$((ref_pairs + 1))
  verdicts="$wax $wt"
  [ "$ref" != '-' ] && verdicts="$verdicts $ref"
  uniq_count="$(printf '%s\n' $verdicts | sort -u | wc -l)"
  if [ "$uniq_count" -ne 1 ]; then
    findings=$((findings + 1))
    if { [ "$wax" != "$wt" ]; } || { [ "$ref" != '-' ] && [ "$wax" != "$ref" ]; }; then
      finding subtype-lattice HIGH "$rel" "wax=$wax wasm-tools=$wt ref=$ref" \
        "printf '%s' (module … (func (param (ref $(echo "$rel" | sed 's/<:.*//')))…"
    else
      finding subtype-lattice REVIEW "$rel" "wax=$wax wasm-tools=$wt ref=$ref" "oracle disagreement"
    fi
  fi
done < <(cat "$RESULTS"/res.* 2>/dev/null)

total="$(cat "$RESULTS"/res.* 2>/dev/null | wc -l)"
echo "checked $total pairs ($accepts accepted / $((total - accepts)) rejected; ref interpreter ruled on $ref_pairs), $findings disagreement(s)" >&2
[ "$findings" -eq 0 ]
