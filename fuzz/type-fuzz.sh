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
#   ROUNDTRIP — an accepted module's binary, decompiled to wax and recompiled,
#               no longer produces a reference-valid binary.
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
        # Round-trip: decompile the binary and recompile; must stay valid.
        local rt="$p.rt.wax" rbin="$p.rt.wasm"
        if [ "$(classify_wax -i wasm "$bin" -f wax -o "$rt")" = ok ] \
           && [ "$(classify_wax -i wax "$rt" -f wasm -o "$rbin")" = ok ]; then
          if ! wt_validate "$rbin"; then
            out+="$(finding TYPE HIGH "gen$i" \
              "ROUNDTRIP: recompiled decompilation is reference-invalid: $(head -1 "$rbin.err")" \
              "fuzz_gen $((SEED + i)) | wax -f wasm | wax -i wasm -f wax | wax -f wasm")"$'\n'; printf F >&2
          fi
        fi
      fi ;;
    # `rejected` is fine: the `err` modules are meant to reject, exercising the
    # checker's mismatch-reporting arms.
  esac

  # Also drive the dedicated `check` path (type-check only, no emission).
  case "$(classify_wax check "$wax")" in
    crash:*) out+="$(finding TYPE HIGH "gen$i" "crash on wax check" "wax check <(fuzz_gen $((SEED + i)) $errflag)")"$'\n'; printf F >&2 ;;
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
echo "=================== type-fuzz report ==================="
echo "modules: $COUNT"
echo "findings (crash / unsound / round-trip): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
