#!/usr/bin/env bash
#
# alias-fuzz.sh [count]
#
# Fuzz value-type aliases, which no other campaign generates: the corpus is
# decompiled from Wasm, which has no aliases. Each iteration takes a valid .wax
# seed and rewrites it with fuzz_alias, replacing some of the value types its
# declarations write by aliases of them (signatures, locals, globals, struct and
# array fields, imports). Aliasing changes nothing about a module, so:
#
#   ALIAS_REJECT   — the aliased module no longer compiles, though the seed does;
#   ALIAS_DIFF     — it compiles to a binary that is not the seed's (an
#                    unconditional alias is mere notation; see same_module for
#                    what "the same" allows).
#
# Then again with the alias definitions placed, identically, in both branches of
# an #[if(fz_cond)]: conditional aliases, which the toolchain keeps in text and
# lowers to a form that holds in every configuration. Each configuration means
# the same as the seed, so:
#
#   COND_DIFF      — under -D fz_cond=true or =false, the binary is not the
#                    seed's;
#   COND_REJECT    — unresolved, the module does not convert to WAT, or the WAT
#                    does not validate, or does not specialize to the binary the
#                    seed compiles to through WAT (compiling through WAT and
#                    directly can differ in metadata, aliases or not);
#   COND_ROUNDTRIP — that WAT does not convert back to Wax, or the result no
#                    longer compiles under -D.
#
# Plus CRASH for any wax invocation that exits other than ok/rejected. Seeds come
# from fuzz/corpus-wax/valid (run fuzz/wax-corpus.sh first); a seed that does not
# compile on its own is skipped. Parallel across seeds; exits non-zero on any
# finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-500}"
SEEDS="${SEEDS:-$ROOT/fuzz/corpus-wax/valid}"
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
KEEP="$ROOT/fuzz/alias-findings"
ALIAS="${ALIAS:-$ROOT/_build/default/src/bin/fuzz_alias.exe}"
[ -x "$ALIAS" ] || { echo "fuzz_alias not built — run 'dune build' first" >&2; exit 2; }
[ -d "$SEEDS" ] && [ -n "$(find "$SEEDS" -name '*.wax' -print -quit)" ] \
  || { echo "no wax seeds at $SEEDS — run fuzz/wax-corpus.sh first" >&2; exit 2; }
mkdir -p "$KEEP"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

mapfile -t SEED_FILES < <(find "$SEEDS" -name '*.wax' | sort)
NSEEDS=${#SEED_FILES[@]}

# Whether two binaries are the same module: byte-identical, or equal up to two
# differences that do not change what the module does. A select of a
# conditional alias's type is a typed select (the alias may be a reference in
# another configuration), where the seed's numeric one is untyped; and the
# declarative element segment a module with conditionals gets once they are
# resolved may list its functions differently (one already declared by an
# export, say), aliases or not.
same_module() {
  cmp -s "$1" "$2" && return 0
  local norm='s/select (result \(i32\|i64\|f32\|f64\|v128\))/select/g; /^ *(elem declare /d'
  diff -q <("$WAX" -f wat "$1" 2>&1 | sed "$norm") \
          <("$WAX" -f wat "$2" 2>&1 | sed "$norm") >/dev/null
}

# Worker: alias seed #i (the seed file and the alias choices both derived from
# $SEED and i), run the oracles, and write any finding to $RESULTS/<i>. A failing
# input is kept under $KEEP.
fuzz_one() {
  local i="$1" seed dir out="" verdict v s
  seed="${SEED_FILES[$(( (i * 2654435761) % NSEEDS ))]}"
  s=$(( SEED + i ))
  dir="$(mktemp -d)"
  ERRLOG="$dir/err"
  # The seed's own binary: the reference every aliased form must reproduce.
  if [ "$(classify_wax -f wasm "$seed" -o "$dir/orig.wasm")" != ok ]; then
    rm -rf "$dir"; printf '.' >&2; return 0
  fi
  keep() { cp "$1" "$KEEP/$(basename "$seed" .wax)-$s-$(basename "$1")"; }
  report() { out+="$(finding "$1" HIGH "$(basename "$seed")" "$2" "$3")"$'\n'; printf F >&2; }

  # Unconditional aliases: notation only.
  "$ALIAS" "$seed" "$s" >"$dir/a.wax" 2>/dev/null || { rm -rf "$dir"; return 0; }
  verdict="$(classify_wax -f wasm "$dir/a.wax" -o "$dir/a.wasm")"
  case "$verdict" in
    ok) same_module "$dir/orig.wasm" "$dir/a.wasm" || {
          keep "$dir/a.wax"
          report ALIAS_DIFF "the aliased module compiles to a different binary" \
            "$ALIAS $seed $s" ; } ;;
    rejected) keep "$dir/a.wax"
      report ALIAS_REJECT "$(grep -m1 -i error "$ERRLOG")" "$ALIAS $seed $s" ;;
    *) keep "$dir/a.wax"; report CRASH "$verdict" "wax -f wasm (alias of $seed, seed $s)" ;;
  esac

  # Conditional aliases, identical in both branches.
  "$ALIAS" "$seed" "$s" fz_cond >"$dir/c.wax" 2>/dev/null || { rm -rf "$dir"; return 0; }
  for v in true false; do
    verdict="$(classify_wax -D "fz_cond=$v" -f wasm "$dir/c.wax" -o "$dir/c-$v.wasm")"
    case "$verdict" in
      ok) same_module "$dir/orig.wasm" "$dir/c-$v.wasm" || {
            keep "$dir/c.wax"
            report COND_DIFF "under -D fz_cond=$v, a different binary" \
              "$ALIAS $seed $s fz_cond" ; } ;;
      rejected) keep "$dir/c.wax"
        report COND_REJECT "-D fz_cond=$v: $(grep -m1 -i error "$ERRLOG")" \
          "$ALIAS $seed $s fz_cond" ;;
      *) keep "$dir/c.wax"; report CRASH "$verdict" "wax -D fz_cond=$v -f wasm (seed $s)" ;;
    esac
  done
  # Unresolved: to WAT, which must validate and specialize to the seed's binary,
  # and back to Wax, which must still compile.
  verdict="$(classify_wax -f wat "$dir/c.wax" -o "$dir/c.wat")"
  if [ "$verdict" = ok ]; then
    verdict="$(classify_wax check "$dir/c.wat")"
    [ "$verdict" = ok ] || { keep "$dir/c.wax"
      report COND_REJECT "the unresolved WAT does not validate: $(grep -m1 -i error "$ERRLOG")" \
        "$ALIAS $seed $s fz_cond | wax -f wat | wax check" ; }
    verdict="$(classify_wax -D fz_cond=true -f wasm "$dir/c.wat" -o "$dir/cw.wasm")"
    if [ "$verdict" = ok ]; then
      "$WAX" -f wat "$seed" -o "$dir/orig.wat" 2>/dev/null
      "$WAX" -f wasm "$dir/orig.wat" -o "$dir/orig-wat.wasm" 2>/dev/null
      same_module "$dir/orig-wat.wasm" "$dir/cw.wasm" || { keep "$dir/c.wax"
        report COND_REJECT "the unresolved WAT specializes to a different binary" \
          "$ALIAS $seed $s fz_cond | wax -f wat | wax -D fz_cond=true -f wasm" ; }
    else
      keep "$dir/c.wax"
      report COND_REJECT "the unresolved WAT does not specialize ($verdict)" \
        "$ALIAS $seed $s fz_cond | wax -f wat | wax -D fz_cond=true -f wasm"
    fi
    verdict="$(classify_wax -f wax "$dir/c.wat" -o "$dir/c2.wax")"
    if [ "$verdict" = ok ]; then
      verdict="$(classify_wax -D fz_cond=false -f wasm "$dir/c2.wax" -o "$dir/c2.wasm")"
      [ "$verdict" = ok ] || { keep "$dir/c.wax"
        report COND_ROUNDTRIP "WAT->Wax no longer compiles ($verdict): $(grep -m1 -i error "$ERRLOG")" \
          "$ALIAS $seed $s fz_cond | wax -f wat | wax -f wax | wax -D fz_cond=false -f wasm" ; }
    else
      keep "$dir/c.wax"
      report COND_ROUNDTRIP "WAT->Wax fails ($verdict): $(grep -m1 -i error "$ERRLOG")" \
        "$ALIAS $seed $s fz_cond | wax -f wat | wax -f wax"
    fi
  else
    keep "$dir/c.wax"
    report COND_REJECT "unresolved, does not convert to WAT ($verdict): $(grep -m1 -i error "$ERRLOG")" \
      "$ALIAS $seed $s fz_cond | wax -f wat"
  fi

  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$i"
  rm -rf "$dir"
  printf '.' >&2
}

announce_seed "$(basename "$0") $COUNT"
echo "aliasing $COUNT seeds (of $NSEEDS) across $JOBS jobs..." >&2
for ((i = 0; i < COUNT; i++)); do
  ( fuzz_one "$i" ) &
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== alias-fuzz report ==================="
echo "aliased seeds: $COUNT"
echo "findings: $n (failing inputs under $KEEP)"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
