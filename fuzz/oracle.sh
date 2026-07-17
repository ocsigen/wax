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
#   6. Wax round-trip — for a wax input, wax -> wasm -> wax -> wasm must still
#                   validate (the dual of 5: tests both directions compose).
#   7. Under-reject — if `check` accepts a text module, converting it to another
#                   format must not then reject it (a typer too lenient for what
#                   lowering requires).
#   8. Lint parity — the same program's wax and wat forms must raise the same set
#                   of warnings (minus the intentionally one-sided lints).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IN="${1:?usage: oracle.sh <input-file> [valid|invalid|unknown]}"
EXPECT="${2:-unknown}"
FMT="$(fmt_of "$IN")"
[ -n "$FMT" ] || { echo "oracle.sh: unknown extension: $IN" >&2; exit 2; }

WORK="$(mktemp -d)"
ERRLOG="$WORK/err"
trap 'rm -rf "$WORK"' EXIT

repro() { echo "$WAX $*"; }

# Count-per-opcode histogram of the *width-sensitive* numeric operators in a
# module — integer div/rem, the shifts (shl/shr), and the (non-saturating)
# float->int truncations. Their WIDTH is load-bearing and NOT carried by the Wax
# surface at every consumer: a dropped/unpinned i64 tree that narrows to i32
# turns a nonzero divisor into 0 (a divide-by-zero trap), a shift count masks to
# the wrong modulus (4096 >>u 40 is 0 as i64, 16 as i32), and a trunc whose
# source float width narrows changes which inputs trap / the value it produces.
# This is the width-eraser class (ROADMAP.md §1), invisible to every validity
# oracle (both sides validate; only execution sees it). No legitimate round-trip
# rewrite touches these families IN REACHABLE CODE (cast fusion only moves
# extend/wrap/reinterpret; div/rem/shift lower straight through; a truncation's
# source is pinned in from_wasm), so any change is a bug — verified
# false-positive-free over the corpus (0 findings; fires on a neutered wax).
#
# Dead code is EXCLUDED from the count (the awk below tracks reachability):
# from_wasm deliberately does not pin widths after a terminator (ROADMAP §1
# "dead code is exempt — never executes"), so a width op on the polymorphic
# dead-code stack legitimately re-defaults (or collapses to `unreachable`) —
# the same reason comparisons/eqz/wrap are excluded entirely. wasm-smith puts
# div/rem/trunc in dead code too (smith-findings/smith-{318,475}.wasm), which
# the corpus never did.
#
# Deliberately EXCLUDED: comparisons, [eqz] and [i32.wrap_i64]. Their width is
# also erased and IS fixed in from_wasm, but they are not histogram-clean: a
# comparison in dead code drifts harmlessly (holes re-default: [f32.eq]->[i32.eq]),
# and a [wrap] is legitimately folded away against an [extend] ([i32.wrap_i64
# (i64.extend_i32_u x)] = x). Those consumers are covered by the deterministic
# [fuzz/drop-width.sh] sweep instead, which controls the operand shape.
#
# Returns non-zero (so the caller skips the check) if the reference cannot print
# the argument — then there is no trustworthy ground truth to compare against.
width_op_histogram() {
  local txt
  txt="$("$WASM_TOOLS" print "$1" 2>/dev/null)" || return 1
  # Reachability tracker over the flat `wasm-tools print` form: after an
  # unconditional terminator, skip lines until the enclosing frame's
  # end/else/catch (nested dead blocks tracked by depth); a lone `)` closes
  # the function. Only live lines reach the opcode grep.
  printf '%s\n' "$txt" \
    | awk '
        { t = $1 }
        t == ")" { dead = 0; depth = 0 }
        t == "block" || t == "loop" || t == "if" || t == "try" || t == "try_table" { depth++ }
        t == "end" || t == "delegate" {
          if (dead && depth == dead_depth) dead = 0
          depth--
        }
        t == "else" || t == "catch" || t == "catch_all" {
          if (dead && depth == dead_depth) dead = 0
        }
        dead { next }
        { print }
        t == "br" || t == "br_table" || t == "return" || t ~ /^return_call/ \
          || t == "unreachable" || t == "throw" || t == "throw_ref" || t == "rethrow" {
          dead = 1; dead_depth = depth
        }' \
    | grep -oE 'i(32|64)\.(div|rem|shr)_[su]|i(32|64)\.shl\b|i(32|64)\.trunc_f(32|64)_[su]\b' \
    | sort | uniq -c
}

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

# Fold/unfold are wat-output-only rewrites (there is no folding on wax output).
# They run on unvalidated (wat->wat) and trusted (wasm->wat) input, so the
# folding pass has its own crash class — see INVARIANTS.md. Sweep both modes so
# it stays covered.
for fold in --fold --unfold; do
  args=(-i "$FMT" -f wat "$fold" "$IN" -o "$WORK/out.wat")
  r="$(classify_wax "${args[@]}")"
  case "$r" in
    crash:*)
      finding CRASH HIGH "$IN" "${r#crash:} on ${FMT}->wat ($fold)" \
        "$(repro "${args[@]}")"
      ;;
  esac
done

# Other wiring paths the convert sweep above does not touch, each its own code
# path: the `format` subcommand (a separate entry point in main.ml), strict
# validation (-s), and warnings-as-errors (-W all=error, exercising the
# diagnostic machinery). Crash-only checks — the verdict may legitimately be a
# clean rejection, only a crash is a finding.
# (`format` writes to stdout, which classify_wax discards — it has no -o flag.)
paths=("format -f $FMT $IN"
       "check -s $IN"
       "-i $FMT -f wasm -W all=error $IN -o $WORK/warn.wasm")
for p in "${paths[@]}"; do
  read -ra args <<<"$p"
  r="$(classify_wax "${args[@]}")"
  case "$r" in
    crash:*)
      finding CRASH HIGH "$IN" "${r#crash:} on: wax $p" "$(repro "${args[@]}")"
      ;;
  esac
done

# ---- 2. Validator correctness: `wax check` vs the ground truth. ----
# `wax check` is the dedicated validation path (type-check Wax / well-formedness
# Wasm); it returns ok or a clean rejection. Compare its verdict to what we know
# about the module. This is the direct test of "Wax typing mirrors Wasm
# validation".
check=(check "$IN")
verdict="$(classify_wax "${check[@]}")"
case "$verdict:$EXPECT" in
  crash:*)
    # `check` is its own code path — the convert crash sweep above does not
    # exercise it, so a crash here would otherwise go unreported.
    finding CRASH HIGH "$IN" "${verdict#crash:} on: wax check $IN" \
      "$(repro "${check[@]}")" ;;
  rejected:valid)
    finding FALSE_REJECT HIGH "$IN" \
      "wax rejected a valid module: $(grep -m1 -i error "$ERRLOG" || true)" \
      "$(repro "${check[@]}")" ;;
  ok:invalid)
    finding FALSE_ACCEPT HIGH "$IN" \
      "wax's validator accepted a module documented as invalid" \
      "$(repro "${check[@]}")" ;;
  ok:unknown|rejected:unknown)
    # No documented verdict: differentially compare against the reference, for
    # any input it can read directly — a wasm binary, or WAT (wasm-tools parses
    # text too), which makes wax's WAT-parser verdict comparable to the
    # reference's parse+validate. REVIEW severity: a mismatch may be a genuine
    # divergence or just a proposal one side parses and the other does not.
    if [ "$FMT" = wasm ] || [ "$FMT" = wat ]; then
      # Compare wax's STRICT verdict against wasm-tools: wasm-tools (like the
      # spec reference interpreter) is always strict on reference validation,
      # whereas wax's default WAT check is deliberately relaxed there — an
      # undeclared [ref.func] target is auto-declared on lowering, so wax
      # accepts what wasm-tools rejects by design (docs/src/cli.md,
      # [--strict-validate]). Without [-s] that documented leniency reports as
      # a spurious divergence. A separate variable so the downstream oracles
      # keep exercising wax's default (relaxed) [$verdict].
      scheck=(check -s "$IN")
      sverdict="$(classify_wax "${scheck[@]}")"
      if wt_validate "$IN"; then ref=ok; else ref=rejected; fi
      report_diff=0
      diffmsg="wax says $sverdict, wasm-tools says $ref"
      if [ "$sverdict" != "$ref" ]; then
        if [ "$FMT" = wat ] && ! grep -q '[^[:space:]]' "$IN"; then
          # A whitespace-only WAT is a valid empty module to wax (and to
          # wat2wasm, which warns but accepts); only wasm-tools refuses a bare
          # empty top-level. That divergence is a reference quirk the text
          # mutator hits whenever it deletes every token — suppress it.
          report_diff=0
        elif [ "$sverdict" = ok ] || [ "$FMT" = wat ]; then
          # wax MORE LENIENT (accepts what the reference rejects — the soundness
          # direction), or any WAT-text divergence: report directly.
          report_diff=1
        else
          # wax rejected a BINARY the reference accepts. wax fully and strictly
          # decodes the binary — including custom sections like `name`, which it
          # must read to recover names for wat/wax output — so it rightly rejects
          # malformed UTF-8 / bad lengths there that the reference leaves opaque.
          # To tell that custom-section noise from a genuine core-decode
          # divergence, strip all custom sections and re-test: if wax now accepts,
          # the rejection was custom-section-only (expected, suppress); if it
          # persists, the core genuinely diverges (report).
          if "$WASM_TOOLS" strip --all "$IN" -o "$WORK/stripped.wasm" 2>/dev/null \
            && [ "$(classify_wax -i wasm -f wat "$WORK/stripped.wasm" -o /dev/null)" = ok ]
          then
            report_diff=0
          else
            report_diff=1
            diffmsg="wax rejects the core (custom sections stripped), wasm-tools accepts"
          fi
        fi
      fi
      if [ "$report_diff" = 1 ]; then
        finding VALIDATOR_DIFF REVIEW "$IN" "$diffmsg" \
          "$(repro "${scheck[@]}"); wasm-tools validate --features all $IN"
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
        "$(repro "${a1[@]}") && $(repro "${a2[@]}") && diff $WORK/fmt1 $WORK/fmt2"
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
    elif orig_hist="$(width_op_histogram "$IN")" \
         && via_hist="$(width_op_histogram "$WORK/via.wasm")" \
         && [ "$orig_hist" != "$via_hist" ]; then
      # The recompiled binary validates but a width-sensitive opcode changed width
      # (or count) — the width-eraser class, which both sides validate through.
      # Generalizes drop-width.sh to arbitrary corpus/smith/mutant inputs, which
      # carry no assertions for the execution oracles.
      finding WIDTHDRIFT HIGH "$IN" \
        "round-trip changed a width-sensitive opcode (div/rem/shift/trunc_f histogram: [${orig_hist//$'\n'/; }] -> [${via_hist//$'\n'/; }])" \
        "$(repro "${wa[@]}") && $(repro "${rb[@]}") && diff <(wasm-tools print $IN | grep -oE 'i(32|64)\.(div|rem|shr)_[su]|i(32|64)\.shl|i(32|64)\.trunc_f(32|64)_[su]') <(wasm-tools print $WORK/via.wasm | grep -oE 'i(32|64)\.(div|rem|shr)_[su]|i(32|64)\.shl|i(32|64)\.trunc_f(32|64)_[su]')"
    fi
  fi
fi

# ---- 6. Wax round-trip stability: wax -> wasm -> wax -> wasm re-validates. ----
# The dual of oracle 5 for a wax input (which 5 skips): compile, then decompile,
# then recompile, and check the result still validates. A break here means the
# two directions do not compose on this program. We start only from a wax->wasm
# that already validates (an invalid emission is oracle 3's FALSE_ACCEPT, not a
# round-trip bug) so the two oracles do not double-report the same root cause.
if [ "$FMT" = wax ]; then
  c1=(-i wax -f wasm "$IN" -o "$WORK/rt1.wasm")
  if [ "$(classify_wax "${c1[@]}")" = ok ] && wt_validate "$WORK/rt1.wasm"; then
    dc=(-i wasm -f wax "$WORK/rt1.wasm" -o "$WORK/rt.wax")
    rdc="$(classify_wax "${dc[@]}")"
    c2=(-i wax -f wasm "$WORK/rt.wax" -o "$WORK/rt2.wasm")
    if [ "$rdc" != ok ]; then
      finding ROUNDTRIP HIGH "$IN" \
        "wax->wasm decompiles back but fails: $rdc" \
        "$(repro "${c1[@]}") && $(repro "${dc[@]}")"
    elif rc2="$(classify_wax "${c2[@]}")"; [ "$rc2" != ok ]; then
      finding ROUNDTRIP HIGH "$IN" \
        "wax->wasm->wax does not recompile: $rc2" \
        "$(repro "${dc[@]}") && $(repro "${c2[@]}")"
    elif ! wt_validate "$WORK/rt2.wasm"; then
      finding ROUNDTRIP HIGH "$IN" \
        "wax->wasm->wax->wasm is rejected by wasm-tools: $(head -1 "$WORK/rt2.wasm.err")" \
        "$(repro "${c1[@]}") && $(repro "${dc[@]}") && $(repro "${c2[@]}") && wasm-tools validate --features all $WORK/rt2.wasm"
    fi
  fi
fi

# ---- 7. Cross-stage consistency: check-accepts => convert-accepts. ----
# `check` (validation) and a cross-format conversion (which runs lowering) must
# agree: once the typer/validator has accepted a text module, lowering it to a
# different format must not then cleanly REJECT it. Such a rejection is an
# under-rejection — the typer accepted something a later stage refuses, breaking
# "Wax typing mirrors Wasm validation" (e.g. an unchecked intrinsic arity, or a
# non-constant operand in a constant position, that only the lowering catches).
# A CRASH in these conversions is already oracle 1's; and a wasm binary input is
# trusted by the converter (not re-validated), so this applies to text input
# only — where the typer is the thing under test. (Reached only with verdict=ok.)
if [ "$FMT" = wat ] || [ "$FMT" = wax ]; then
  for out in wat wax wasm; do
    [ "$out" = "$FMT" ] && continue # same-format is a reprint, not a lowering
    conv=(-i "$FMT" -f "$out" "$IN" -o "$WORK/conv.$out")
    if [ "$(classify_wax "${conv[@]}")" = rejected ]; then
      finding UNDER_REJECT REVIEW "$IN" \
        "wax check accepts but ${FMT}->${out} rejects it (typer under-rejects): $(grep -m1 -i error "$ERRLOG" || true)" \
        "$(repro "${check[@]}") && $(repro "${conv[@]}")"
    fi
  done
fi

# ---- 8. Lint parity: the same program lints the same as wax and as wat. ----
# The typer (lib-wax) and the validator (lib-wasm) mirror most lints, so a
# warning that fires on one text form but not the equivalent other is a parity
# break (e.g. shift-count-overflow, a tautological comparison, a constant trap).
# Compare the SET of warning codes — locations differ between the two forms —
# minus the intentionally one-sided lints (precedence is wax-only; eager-select's
# wasm side covers only folded selects; the naming lints fire only while
# decompiling wasm->wax, never in a `check`).
lint_codes() { # $1 = file (format from extension): its sorted-unique warn codes
  timeout -k 5 "$TIMEOUT" "$WAX" check -W all=warning \
    --error-format json "$1" 2>&1 >/dev/null \
    | grep -oE '"warning":"[^"]+"' | sed 's/.*:"//; s/"$//' \
    | grep -vxE 'precedence|eager-select|naming-conflict|reserved-word-rename|generated-name' \
    | sort -u
}
# Obtain both text forms (converting as needed); skip if either conversion fails.
waxf="$IN"
watf="$IN"
[ "$FMT" = wax ] || {
  waxf="$WORK/parity.wax"
  [ "$(classify_wax -i "$FMT" -f wax "$IN" -o "$waxf")" = ok ] || waxf=""
}
[ "$FMT" = wat ] || {
  watf="$WORK/parity.wat"
  [ "$(classify_wax -i "$FMT" -f wat "$IN" -o "$watf")" = ok ] || watf=""
}
if [ -n "$waxf" ] && [ -n "$watf" ]; then
  cwax="$(lint_codes "$waxf")"
  cwat="$(lint_codes "$watf")"
  if [ "$cwax" != "$cwat" ]; then
    only_wax="$(comm -23 <(printf '%s\n' "$cwax") <(printf '%s\n' "$cwat") | paste -sd, -)"
    only_wat="$(comm -13 <(printf '%s\n' "$cwax") <(printf '%s\n' "$cwat") | paste -sd, -)"
    finding LINT_PARITY REVIEW "$IN" \
      "lint sets differ between the wax and wat form (wax-only: ${only_wax:-none}; wat-only: ${only_wat:-none})" \
      "wax check -W all=warning $waxf; wax check -W all=warning $watf"
  fi
fi

exit 0
