#!/usr/bin/env bash
#
# type-fuzz.sh
#
# Fuzz the Wax type checker (lib-wax/typing.ml) with generated hand-written-style
# Wax source (the fuzz_gen AST generator). The .wax the other oracles type-check
# is DECOMPILED from wasm (mutate-wax / diff-validate seeds), so it only contains
# the constructs from_wasm emits — never the surface sugar a human writes (infix
# operators and their signed/unsigned variants, `as` conversions, method
# intrinsics, `if`/`?:` with inferred result types), which is exactly what large
# parts of typing.ml exist to check. fuzz_gen emits that sugar, type-directed so
# it type-checks, plus (with `err`) a single deliberate mismatch for the
# rejection arms.
#
# fuzz_gen builds a real AST and prints it through Wax_lang.Output, so the source
# always re-parses: a rejection is a genuine type verdict, never a syntax slip.
# Oracles per module (the checker-soundness invariant "Wax typing mirrors Wasm
# validation"):
#
#   UNSOUND   — wax's type checker accepts the module (`-f wasm --validate` ok)
#               but the binary it emits is rejected by the reference validator: a
#               hole in the type checker.
#   ROUNDTRIP — an accepted module's binary fails to decompile to wax, the
#               decompilation fails to recompile, or the recompiled binary is no
#               longer reference-valid. Since the binary is one wax emitted and
#               the reference accepted, every step must succeed: a crash or
#               rejection at any of them is a finding (e.g. a decompiler scoping
#               bug surfaces as an unbound-variable rejection *during* decompile).
#   ROUNDTRIP-WAT — same, but through the wat *text* form (wax->wat->wax->wasm):
#               covers the wat printer/parser (e.g. the branch-hint annotation)
#               that the binary round-trip never touches.
#   CRASH     — type-checking or emission exits other than ok/rejected.
#
# A clean rejection is never a finding (the `err` modules are meant to reject;
# it exercises the mismatch arms). Deterministic given SEED; needs wasm-tools.
# Parallel; exits non-zero on any HIGH finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v "$WASM_TOOLS" >/dev/null 2>&1; then
  echo "type-fuzz: wasm-tools not found (needed as the validity oracle)" >&2
  exit 2
fi

GEN_EXE="${GEN_EXE:-$ROOT/_build/default/src/bin/fuzz_gen.exe}"
[ -x "$GEN_EXE" ] || { echo "fuzz_gen not built — run 'dune build' first" >&2; exit 2; }

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
COUNT="${COUNT:-400}"       # modules to generate; a fraction get a planted type error
ERR_EVERY="${ERR_EVERY:-4}" # every Nth module is generated with a deliberate error
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Worker: generate module [i] from a seed derived from SEED, then run the oracle.
fuzz_one() {
  local i="$1" p="$RESULTS/w$1"
  ERRLOG="$p.err"
  local wax="$p.wax" bin="$p.wasm" out=""
  local errflag=""
  [ $((i % ERR_EVERY)) -eq 0 ] && errflag="err"
  "$GEN_EXE" "$((SEED + i))" $errflag >"$wax" 2>/dev/null

  # wax's own verdict (source type checker) + emission.
  local v; v="$(classify_wax -i wax "$wax" -f wasm --validate -o "$bin")"
  case "$v" in
    crash:*)
      out+="$(finding TYPE HIGH "gen$i" "$v type-checking generated module" \
        "fuzz_gen $((SEED + i)) $errflag | wax -i wax -f wasm --validate")"$'\n'; printf F >&2 ;;
    ok)
      if ! wt_validate "$bin"; then
        out+="$(finding TYPE HIGH "gen$i" \
          "UNSOUND: type checker accepted but binary rejected: $(head -1 "$bin.err")" \
          "fuzz_gen $((SEED + i)) | wax -f wasm -o m.wasm && wasm-tools validate m.wasm")"$'\n'; printf F >&2
      else
        # Round-trip: a binary wax emitted and the reference validated must
        # decompile and recompile cleanly, and the recompiled binary must stay
        # reference-valid. A crash or rejection at ANY step is a finding — not a
        # skip. (An earlier version guarded the whole round-trip on each step
        # being `ok` and only reported a reference-INVALID recompilation, so a
        # decompiler that crashed or rejected its own valid input slipped
        # through silently — e.g. a sink_let scoping bug surfaces as an
        # unbound-variable rejection *during decompilation*, never reaching the
        # validity check.)
        local rt="$p.rt.wax" rbin="$p.rt.wasm" r
        r="$(classify_wax -i wasm "$bin" -f wax -o "$rt")"
        if [ "$r" != ok ]; then
          out+="$(finding TYPE HIGH "gen$i" \
            "ROUNDTRIP: decompiling a reference-valid binary failed ($r): $(head -1 "$ERRLOG")" \
            "fuzz_gen $((SEED + i)) | wax -f wasm | wax -i wasm -f wax")"$'\n'; printf F >&2
        else
          r="$(classify_wax -i wax "$rt" -f wasm -o "$rbin")"
          if [ "$r" != ok ]; then
            out+="$(finding TYPE HIGH "gen$i" \
              "ROUNDTRIP: recompiling the decompilation failed ($r): $(head -1 "$ERRLOG")" \
              "fuzz_gen $((SEED + i)) | wax -f wasm | wax -i wasm -f wax | wax -f wasm")"$'\n'; printf F >&2
          elif ! wt_validate "$rbin"; then
            out+="$(finding TYPE HIGH "gen$i" \
              "ROUNDTRIP: recompiled decompilation is reference-invalid: $(head -1 "$rbin.err")" \
              "fuzz_gen $((SEED + i)) | wax -f wasm | wax -i wasm -f wax | wax -f wasm")"$'\n'; printf F >&2
          fi
        fi
        # Wat round-trip: the same module via the wat *text* form, which the
        # binary path never exercises — the wat printer and parser of the
        # branch-hint annotation ([(@metadata.code.branch_hint …)]) in
        # particular. Each step (wax->wat, wat->wax, wax->wasm) must succeed and
        # the result stay reference-valid; a failure at any step is a finding.
        local wat="$p.wat" wat_rt="$p.wat.wax" wat_bin="$p.wat.wasm"
        r="$(classify_wax -i wax "$wax" -f wat -o "$wat")"
        if [ "$r" != ok ]; then
          out+="$(finding TYPE HIGH "gen$i" \
            "ROUNDTRIP-WAT: printing a valid module to wat failed ($r): $(head -1 "$ERRLOG")" \
            "fuzz_gen $((SEED + i)) | wax -f wat")"$'\n'; printf F >&2
        else
          r="$(classify_wax -i wat "$wat" -f wax -o "$wat_rt")"
          if [ "$r" != ok ]; then
            out+="$(finding TYPE HIGH "gen$i" \
              "ROUNDTRIP-WAT: decompiling valid wat failed ($r): $(head -1 "$ERRLOG")" \
              "fuzz_gen $((SEED + i)) | wax -f wat | wax -i wat -f wax")"$'\n'; printf F >&2
          else
            r="$(classify_wax -i wax "$wat_rt" -f wasm -o "$wat_bin")"
            if [ "$r" != ok ]; then
              out+="$(finding TYPE HIGH "gen$i" \
                "ROUNDTRIP-WAT: recompiling the wat decompilation failed ($r): $(head -1 "$ERRLOG")" \
                "fuzz_gen $((SEED + i)) | wax -f wat | wax -i wat -f wax | wax -f wasm")"$'\n'; printf F >&2
            elif ! wt_validate "$wat_bin"; then
              out+="$(finding TYPE HIGH "gen$i" \
                "ROUNDTRIP-WAT: recompiled wat round-trip is reference-invalid: $(head -1 "$wat_bin.err")" \
                "fuzz_gen $((SEED + i)) | wax -f wat | wax -i wat -f wax | wax -f wasm")"$'\n'; printf F >&2
            fi
          fi
        fi
      fi ;;
    # `rejected` is fine: the `err` modules are meant to reject, exercising the
    # checker's mismatch-reporting arms.
  esac

  # Also drive the dedicated `check` path (type-check only, no emission).
  case "$(classify_wax check "$wax")" in
    crash:*) out+="$(finding TYPE HIGH "gen$i" "crash on wax check" "wax check <(fuzz_gen $((SEED + i)) $errflag)")"$'\n'; printf F >&2 ;;
    rejected)
      # Diagnostics-shape invariant on the rejection (the Wax mirror of
      # oracle.sh's 2b): a rejection must not repeat a located diagnostic
      # line — a location+message duplicate means one broken construct was
      # reported twice. The `err` modules exercise this on every mismatch arm
      # the generator can plant.
      local dup
      dup="$(NO_COLOR=1 timeout -k 5 "$TIMEOUT" "$WAX" check --error-format short "$wax" 2>&1 >/dev/null \
        | grep -E '^[^ ]+:[0-9]+:[0-9]+: ' | sort | uniq -d)"
      if [ -n "$dup" ]; then
        out+="$(finding TYPE REVIEW "gen$i" \
          "DIAG_DUP: duplicated diagnostic: $(head -1 <<<"$dup")" \
          "fuzz_gen $((SEED + i)) $errflag >m.wax; wax check --error-format short m.wax 2>&1 | sort | uniq -d")"$'\n'
        printf F >&2
      fi ;;
  esac

  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$i"
  printf '.' >&2
}

announce_seed "$(basename "$0")"
echo "type-fuzzing $COUNT generated modules (1/$ERR_EVERY with a planted error) across $JOBS jobs..." >&2
i=0
while [ "$i" -lt "$COUNT" ]; do
  ( fuzz_one "$i" ) &
  i=$((i + 1))
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "=================== type-fuzz report ==================="
echo "modules: $COUNT"
echo "findings (crash / unsound / round-trip / diag-dup): $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$h" -gt 0 ] && exit 1
exit 0
