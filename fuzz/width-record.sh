#!/usr/bin/env bash
#
# width-record.sh
#
# The recording-gap RATCHET of the width-drift family. The decompiler keeps
# widths faithful by RECORDING, on every value node it emits, the type the
# source opcode states ([Ast.expectation]'s [Recorded]; [Contextual] where the
# width comes from context by design), and letting the typer's reconciliation
# pin whatever would re-infer differently ([Typing.f]'s [~width_check]). That
# machinery has exactly one SILENT failure class: an emission path that records
# nothing at all ([Unset]) — invisible to the reconciliation by construction,
# so it can only surface as a drift a round-trip oracle happens to hit
# (historically: unrecorded v128 loads and v128 globals read as reference
# backings, unrecorded size/grow results of IMPORTED memories/tables).
#
# [--debug width-record] makes the class enumerable instead of probabilistic:
# on a wasm/wat -> wax conversion it reports every numeric-or-v128-valued node
# whose expectation is still [Unset]. This guard sweeps it across the harvested
# corpora and fails on ANY report, so a new [From_wasm] emission path that
# forgets to record (or to mark [Contextual]) fails the gate on the first
# corpus module that exercises it — no drift, no fuzzing luck needed. That is
# the census's contract: [Unset] is reserved for gaps; every deliberate
# no-claim position is marked [Contextual] at its construction site.
#
# A report here is triaged to one of two fixes in [from_wasm.ml]: the path must
# RECORD what its opcode states ([expect]/[push_num]), or the position's type is
# fixed by its context/printed construct and the node is marked [contextual]
# (with the reasoning in a comment). Never widen this guard's filters to hide
# one.
#
# Deterministic, corpus-driven, wax-only (no wasm-tools). Exits 2 (skip) when
# no corpus has been built (run build-corpus.sh / wat-corpus.sh first). Like
# every guard here it tests the binary [_build] currently holds and never
# builds one, so run [dune build] first.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 2 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

DIRS=()
for d in "$ROOT/fuzz/corpus/valid" "$ROOT/fuzz/corpus-wat/valid"; do
  [ -d "$d" ] && DIRS+=("$d")
done
if [ "${#DIRS[@]}" -eq 0 ]; then
  echo "width-record: no corpus found (run fuzz/build-corpus.sh); skipping" >&2
  exit 2
fi

export WAX RESULTS
scan_one() {
  local f="$1" out
  out="$(timeout -k 5 20 "$WAX" --debug width-record -f wax "$f" 2>&1 >/dev/null \
         | grep '^width-record:')"
  if [ -n "$out" ]; then
    {
      echo "== $f"
      echo "$out"
    } >>"$RESULTS/$(basename "$f").finding"
  fi
}
export -f scan_one

total=0
for d in "${DIRS[@]}"; do
  n=$(find "$d" -maxdepth 1 -type f \( -name '*.wasm' -o -name '*.wat' \) | wc -l)
  total=$((total + n))
  find "$d" -maxdepth 1 -type f \( -name '*.wasm' -o -name '*.wat' \) -print0 \
    | xargs -0 -P "$JOBS" -I {} bash -c 'scan_one "$@"' _ {}
done

findings=$(ls "$RESULTS" 2>/dev/null | wc -l)
echo "=================== width-record report ===================" >&2
echo "modules scanned: $total" >&2
echo "recording gaps:  $findings" >&2
if [ "$findings" -gt 0 ]; then
  cat "$RESULTS"/*.finding >&2
  echo "an [Unset] numeric node in From_wasm output is a recording gap:" >&2
  echo "record the opcode's type, or mark the position [contextual] with why" >&2
  exit 1
fi
exit 0
