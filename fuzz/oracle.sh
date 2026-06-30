#!/usr/bin/env bash
#
# oracle.sh <input-file> [expected-validity]
#
# Run every applicable correctness oracle on a single input file and print one
# FINDING line per problem to stdout. This is the unit the fuzzer drives: a
# corpus runner, a mutator, or wasm-smith all just produce a file and call this.
#
# expected-validity (optional): valid | invalid | unknown (default unknown).
#   valid   — the module is known to be a valid wasm module (e.g. from the spec
#             suite). A clean rejection by wax is then a FALSE-REJECT finding.
#   invalid — known invalid. wax accepting it (and emitting a binary the
#             reference accepts) is a FALSE-ACCEPT finding.
#   unknown — only crashes, idempotence, and round-trip equivalence are checked.
#
# Oracles, none of which need a golden file (so they work on generated input):
#   1. Crash      — no pipeline may exit other than 0 (ok) or 128 (clean error).
#   2. Diff-valid — a binary wax emits must be accepted by `wasm-tools validate`
#                   (a false accept means wax produces invalid wasm).
#   3. Validity   — wax's accept/reject verdict matches the known ground truth.
#   4. Idempotence— format(format(x)) == format(x), textually.
#   5. Round-trip — x -> wasm  and  x -> wax -> wasm  must be semantically equal
#                   (canonicalised with `wasm-tools print`). Tests the whole
#                   decompile+recompile path's fidelity.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IN="${1:?usage: oracle.sh <input-file> [valid|invalid|unknown]}"
EXPECT="${2:-unknown}"
FMT="$(fmt_of "$IN")"
[ -n "$FMT" ] || { echo "oracle.sh: unknown extension: $IN" >&2; exit 2; }

WORK="$(mktemp -d)"
ERRLOG="$WORK/err"
trap 'rm -rf "$WORK"' EXIT

repro() { echo "$WAX $*"; }

# ---- 1. Crash sweep: convert to every target format, with and without -v. ----
# Pure conversion must never crash regardless of validity; validation (-v) adds
# the typing/well-formedness paths.
for v in "" "-v"; do
  for out in wat wax wasm; do
    args=(-i "$FMT" -f "$out" $v "$IN" -o "$WORK/out.$out")
    r="$(classify_wax "${args[@]}")"
    case "$r" in
      crash:*)
        finding CRASH HIGH "$IN" "${r#crash:} on ${FMT}->${out}${v:+ (validate)}" \
          "$(repro "${args[@]}")"
        ;;
    esac
  done
done

# ---- 2. Validator correctness: `wax check` vs the ground truth. ----
# `wax check` is the dedicated validation path (type-check Wax / well-formedness
# Wasm); it returns ok or a clean rejection. Compare its verdict to what we know
# about the module. This is the direct test of "Wax typing mirrors Wasm
# validation".
check=(check "$IN")
verdict="$(classify_wax "${check[@]}")"
case "$verdict:$EXPECT" in
  crash:*) : ;;                       # already reported by the crash sweep
  rejected:valid)
    finding FALSE_REJECT HIGH "$IN" \
      "wax rejected a valid module: $(grep -m1 -i error "$ERRLOG" || true)" \
      "$(repro "${check[@]}")" ;;
  ok:invalid)
    finding FALSE_ACCEPT HIGH "$IN" \
      "wax's validator accepted a module documented as invalid" \
      "$(repro "${check[@]}")" ;;
  ok:unknown|rejected:unknown)
    # No documented verdict: differentially compare against the reference, but
    # only when the reference can read the input directly (wasm binary).
    if [ "$FMT" = wasm ]; then
      if wt_validate "$IN"; then ref=ok; else ref=rejected; fi
      if [ "$verdict" != "$ref" ]; then
        finding VALIDATOR_DIFF REVIEW "$IN" \
          "wax says $verdict, wasm-tools says $ref" \
          "$(repro "${check[@]}"); wasm-tools validate --features all $IN"
      fi
    fi ;;
esac

# ---- 3. Emitter soundness: if wax accepts it, its binary must validate. ----
# Catches wax emitting an invalid binary from a module it considered valid
# (a bug in conversion/encoding, not validation). Only run when wax accepts.
if [ "$verdict" = ok ]; then
  emit=(-i "$FMT" -f wasm "$IN" -o "$WORK/cand.wasm")
  if [ "$(classify_wax "${emit[@]}")" = ok ] && ! wt_validate "$WORK/cand.wasm"; then
    finding FALSE_ACCEPT HIGH "$IN" \
      "wax accepted the module but emitted a binary wasm-tools rejects: $(head -1 "$WORK/cand.wasm.err")" \
      "$(repro "${emit[@]}") && wasm-tools validate --features all $WORK/cand.wasm"
  fi
fi

# The remaining oracles only make sense when wax accepts the input.
[ "$verdict" = ok ] || exit 0

# ---- 4. Idempotence: formatting is a fixed point. ----
# Only for text formats (binary "formatting" is re-encoding, covered elsewhere).
if [ "$FMT" = wat ] || [ "$FMT" = wax ]; then
  a1=(-i "$FMT" -f "$FMT" "$IN" -o "$WORK/fmt1")
  if [ "$(classify_wax "${a1[@]}")" = ok ]; then
    a2=(-i "$FMT" -f "$FMT" "$WORK/fmt1" -o "$WORK/fmt2")
    if [ "$(classify_wax "${a2[@]}")" = ok ] \
       && ! diff -q "$WORK/fmt1" "$WORK/fmt2" >/dev/null; then
      finding IDEMPOTENCE REVIEW "$IN" \
        "format is not a fixed point (fmt1 != fmt2)" \
        "$(repro "${a1[@]}"); diff <(...) <(...)"
    fi
  fi
fi

# ---- 5. Round-trip: the decompiled wax must recompile to a valid binary. ----
# Skip when the input is already wax (the via-wax path would be the identity).
# We deliberately do NOT textually compare x->wasm against x->wax->wasm: wax
# legitimately reorders locals, renumbers/dedups types and rewrites the name
# section, so two semantically-equal binaries differ textually. Instead we check
# that decompilation produces wax that recompiles AND that the reference
# validator accepts the result — catching round-trips that quietly corrupt the
# module. Behavioural equivalence is left to the execution oracle (see README).
if [ "$FMT" != wax ]; then
  wa=(-i "$FMT" -f wax "$IN" -o "$WORK/mid.wax")
  if [ "$(classify_wax "${wa[@]}")" = ok ]; then
    rb=(-i wax -f wasm "$WORK/mid.wax" -o "$WORK/via.wasm")
    r="$(classify_wax "${rb[@]}")"
    if [ "$r" != ok ]; then
      finding ROUNDTRIP HIGH "$IN" \
        "x->wax does not recompile (${r#crash:}${r/ok/})" \
        "$(repro "${wa[@]}") && $(repro "${rb[@]}")"
    elif ! wt_validate "$WORK/via.wasm"; then
      finding ROUNDTRIP HIGH "$IN" \
        "x->wax->wasm is rejected by wasm-tools: $(head -1 "$WORK/via.wasm.err")" \
        "$(repro "${wa[@]}") && $(repro "${rb[@]}") && wasm-tools validate --features all $WORK/via.wasm"
    fi
  fi
fi

exit 0
