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
#                    seed compiles to through WAT, up to type identity (a
#                    function typed with an alias gets a type of its own, where
#                    the seed reuses an equal one; compiling through WAT and
#                    directly can differ in metadata, aliases or not);
#   COND_ROUNDTRIP — that WAT does not convert back to Wax, or the result no
#                    longer compiles under -D.
#
# Then with the [#[else]] branch defining each alias as a neighbouring type
# (i32/i64, f32/f64; for a reference, the other nullability, a related struct
# type or the other hierarchy), cast targets aliased too, some operands wrapped
# in a block whose result is left to the context, and some statements
# placed in one or both branches of an #[if(fz_cond_2)]: the module means something
# different in each configuration, where it is valid at all. Converting it
# unresolved, as one module for every configuration, must agree with converting
# each configuration:
#
#   COMMUTE        — the module converts unresolved, and a configuration
#                    compiles on its own, but the converted module specialized
#                    to that configuration does not compile, or is not the same
#                    module (compared by fuzz_canon, up to type identity: a
#                    duplicated type is the same type, a different one is not;
#                    and up to identity casts, see same_canonical);
#   COMMUTE_REJECT — every configuration compiles on its own, but the module
#                    does not convert unresolved, and not because a construct
#                    has no single WebAssembly form (the one rejection that is
#                    by design): an over-rejection, or a form that differs
#                    between configurations the typer does not report, caught
#                    only by validating the lowered module.
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
CANON="${CANON:-$ROOT/_build/default/src/bin/fuzz_canon.exe}"
[ -x "$ALIAS" ] && [ -x "$CANON" ] \
  || { echo "fuzz_alias/fuzz_canon not built — run 'dune build' first" >&2; exit 2; }
[ -d "$SEEDS" ] && [ -n "$(find "$SEEDS" -name '*.wax' -print -quit)" ] \
  || { echo "no wax seeds at $SEEDS — run fuzz/wax-corpus.sh first" >&2; exit 2; }
mkdir -p "$KEEP"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"
# Snapshot the helpers too, so a rebuild during the run does not pull them away.
cp "$ALIAS" "$RESULTS/.fuzz_alias" && ALIAS="$RESULTS/.fuzz_alias"
cp "$CANON" "$RESULTS/.fuzz_canon" && CANON="$RESULTS/.fuzz_canon"

mapfile -t SEED_FILES < <(find "$SEEDS" -name '*.wax' | sort)
NSEEDS=${#SEED_FILES[@]}

# Whether two binaries are the same module: byte-identical, or equal up to three
# differences that do not change what the module does. A select of a
# conditional alias's type is a typed select (the alias may be a reference in
# another configuration), where the seed's numeric one is untyped; the
# declarative element segment a module with conditionals gets once they are
# resolved may list its functions differently (one already declared by an
# export, say), aliases or not; and the source type of a br_on_cast(_fail),
# which a module lowered as one for every configuration takes from one of them
# where -D takes the configuration's own (an immediate is a reftype, which has
# no alias to defer to): the cast tests the target type only.
NORM='s/select (result \(i32\|i64\|f32\|f64\|v128\))/select/g; /^ *(elem declare /d; s/\(br_on_cast\(_fail\)\? [^ ]*\) \(([^()]*\(([^()]*)[^()]*\)*)\|[a-z0-9]*ref\) /\1 /g'
same_module() {
  cmp -s "$1" "$2" && return 0
  diff -q <("$WAX" -f wat "$1" 2>&1 | sed "$NORM") \
          <("$WAX" -f wat "$2" 2>&1 | sed "$NORM") >/dev/null
}

# Whether two binaries are the same module up to type identity (see fuzz_canon):
# a type spelled twice is still one type. Rendered under the worker's $dir.
#
# Also the same when the only difference is ref.casts the first (a
# configuration compiled on its own) has and the second (the module converted
# unresolved) lacks, and they are identity casts: a cast to a conditional alias
# of a value that already has the alias's type lowers to nothing unresolved, as
# no single immediate names the alias in every configuration, while -D resolves
# the alias and keeps the source's redundant cast. A cast its operand's static
# type already satisfies never traps, and the simplifying decompiler drops
# exactly those, so the two must agree once both have been through it; any
# other dropped cast still differs.
same_canonical() {
  "$CANON" "$1" "$dir/canon1.txt" "$2" "$dir/canon2.txt" || return 1
  diff <(sed "$NORM" "$dir/canon1.txt") <(sed "$NORM" "$dir/canon2.txt") \
    >"$dir/canon.diff" && return 0
  grep '^[<>]' "$dir/canon.diff" | grep -qv '^< *ref\.cast ' && return 1
  local f
  for f in 1 2; do
    "$WAX" -f wax "${!f}" -o "$dir/simpl$f.wax" 2>/dev/null \
      && "$WAX" -f wasm "$dir/simpl$f.wax" -o "$dir/simpl$f.wasm" 2>/dev/null \
      || return 1
  done
  "$CANON" "$dir/simpl1.wasm" "$dir/canon1.txt" "$dir/simpl2.wasm" "$dir/canon2.txt" \
    && diff -q <(sed "$NORM" "$dir/canon1.txt") <(sed "$NORM" "$dir/canon2.txt") >/dev/null
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
      same_canonical "$dir/orig-wat.wasm" "$dir/cw.wasm" || { keep "$dir/c.wax"
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

  # Differing aliases: unresolved conversion must commute with -D.
  if "$ALIAS" "$seed" "$s" fz_cond differ >"$dir/d.wax" 2>/dev/null; then
    verdict="$(classify_wax -f wat "$dir/d.wax" -o "$dir/d.wat")"
    cp "$ERRLOG" "$dir/d.err"
  else
    verdict=skipped
  fi
  if [ "$verdict" = rejected ]; then
    local all_compile=true
    for v in true false; do
      for v2 in true false; do
        [ "$(classify_wax -D "fz_cond=$v" -D "fz_cond_2=$v2" -f wasm "$dir/d.wax" -o "$dir/dd.wasm")" = ok ] \
          || all_compile=false
      done
    done
    if $all_compile \
       && ! tr -s ' \n' ' ' <"$dir/d.err" | grep -qi "no single WebAssembly form"; then
      keep "$dir/d.wax"
      report COMMUTE_REJECT "every configuration compiles, but unresolved: $(grep -m1 -i error "$dir/d.err")" \
        "$ALIAS $seed $s fz_cond differ | wax -f wat"
    fi
  elif [ "$verdict" != ok ] && [ "$verdict" != skipped ]; then
    keep "$dir/d.wax"
    report CRASH "$verdict" "$ALIAS $seed $s fz_cond differ | wax -f wat"
  fi
  if [ "$verdict" = ok ]; then
    for v in true false; do
      for v2 in true false; do
        local defs=(-D "fz_cond=$v" -D "fz_cond_2=$v2") cfg="fz_cond=$v fz_cond_2=$v2"
        [ "$(classify_wax "${defs[@]}" -f wasm "$dir/d.wax" -o "$dir/dd.wasm")" = ok ] \
          || continue
        verdict="$(classify_wax "${defs[@]}" -f wasm "$dir/d.wat" -o "$dir/dw.wasm")"
        if [ "$verdict" != ok ]; then
          keep "$dir/d.wax"
          report COMMUTE "converted unresolved, does not compile under $cfg ($verdict)" \
            "$ALIAS $seed $s fz_cond differ | wax -f wat | wax ${defs[*]} -f wasm"
        elif ! same_canonical "$dir/dd.wasm" "$dir/dw.wasm"; then
          keep "$dir/d.wax"
          report COMMUTE "under $cfg, converting unresolved then specializing differs from specializing" \
            "$ALIAS $seed $s fz_cond differ  (compare ${defs[*]} on the .wax and on its unresolved .wat)"
        fi
      done
    done
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
