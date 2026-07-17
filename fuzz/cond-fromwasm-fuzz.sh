#!/usr/bin/env bash
#
# cond-fromwasm-fuzz.sh
#
# A deterministic guard on the from_wasm (wat -> wax) conversion of conditional
# modules — the direction cond-fuzz.sh (which drives Wax seeds forward) never
# exercises. from_wasm walks a function body many times (to reserve names, to
# find the used locals, to collect element-segment and implicit-type references);
# each walker must descend into instruction-level `(@if …)` bodies, or an entity
# referenced ONLY inside a conditional is missed. The symptoms:
#
#   - a parameter used only inside `(@if)` is treated as unused and rendered
#     anonymously, so its `local.get` later resolves to nothing;
#   - a memory/global/data/elem referenced only inside `(@if)` is not reserved,
#     so a generated local name shadows it (or a numeric guard trips);
#   - a declarative element segment `elem.drop`ped only inside `(@if)` loses its
#     declaration and its name is unbound.
#
# All are OVER-REJECTIONS: the module is well-formed (`wax check` accepts every
# reachable configuration), yet `wax -i wat -f wax` fails. So the oracle is a
# differential:
#
#   OVER_REJECT — `wax check` accepts but `wax -i wat -f wax` rejects. HIGH.
#   CRASH       — either exits with an internal-error / signal code. HIGH.
#   RT_INVALID  — both accept, but for some `-D` a specialised round trip
#                 (wat->wax->wasm) fails to validate though the specialised
#                 original does: the conversion changed a reachable
#                 configuration (e.g. an implicit type miscount). HIGH.
#
# Each built-in seed references exactly one module entity from inside an
# `(@if $D …)` body, and (where a name collision is the risk) leaves the
# enclosing function's parameter unnamed so it competes for a generated name.
# Deterministic, parallel, wax-only. Exits non-zero on any HIGH finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Each seed references one entity ONLY inside (@if $D (@then …)). The `$D`
# variable is resolved by -D for the round-trip validation.
BASE="$RESULTS/base"; mkdir -p "$BASE"
seed() { printf '%s\n' "$2" >"$BASE/$1.wat"; }

# Parameter used only inside (@if): must not be treated as unused.
seed s01_param '(module (func (param i32) (result i32)
  (@if $D (@then (local.get 0)) (@else (i32.const 1)))))'

# Global read only inside (@if), with an unnamed param competing for a name.
seed s02_global '(module (global $x i32 (i32.const 3))
  (func (param i32) (result i32)
    (@if $D (@then (global.get $x)) (@else (local.get 0)))))'

# Plain memory access only inside (@if); memory named like the param fallback.
seed s03_memory '(module (memory $x 1)
  (func (param i32) (result i32)
    (@if $D (@then (i32.load (local.get 0))) (@else (local.get 0)))))'

# Atomic memory access only inside (@if): the memory-receiver walker must count
# atomics too (else the unnamed param grabs the memory name).
seed s04_atomic '(module (memory $x 1 1 shared)
  (func (param i32) (result i32)
    (@if $D (@then (i32.atomic.load (local.get 0))) (@else (local.get 0)))))'

# Declarative element segment elem.dropped only inside (@if): keep its
# declaration and bind its name.
seed s05_elem '(module (func $h) (elem declare func $h)
  (func $g (@if $D (@then (elem.drop 0)))))'

# Passive data segment dropped only inside (@if).
seed s06_data '(module (memory 1) (data $d "x")
  (func (@if $D (@then (data.drop $d)))))'

# Table access only inside (@if).
seed s07_table '(module (table $t 1 funcref)
  (func (param i32) (result funcref)
    (@if $D (@then (table.get $t (local.get 0))) (@else (ref.null func)))))'

# ref.func to a declared function only inside (@if).
seed s08_reffunc '(module (func $h) (elem declare func $h)
  (func (result funcref)
    (@if $D (@then (ref.func $h)) (@else (ref.null func)))))'

# A block with an inline signature (an implicit type) only inside (@if).
seed s09_blocktype '(module
  (func (param i32) (result i32)
    (@if $D
      (@then (block (param i32) (result i32) (i32.const 1) (i32.add) (return))
             (i32.const 0))
      (@else (local.get 0)))))'

mapfile -t BASES < <(find "$BASE" -name '*.wat' | sort)
N=${#BASES[@]}

worker() {
  local first="$1" last="$2" i base out=""
  local p="$RESULTS/w$first"
  local wax="$p.wax" chk conv v rt
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    base="${BASES[$i]}"
    chk="$(classify_wax check "$base")"
    conv="$(classify_wax -i wat -f wax "$base" -o "$wax")"
    if [ "$chk" = ok ] && [ "$conv" != ok ]; then
      out+="$(finding CONDFROMWASM HIGH "$(basename "$base")" \
        "wax check accepts but wat->wax gives '$conv'" "$(cat "$base")")"$'\n'
      printf F >&2; continue
    fi
    if [ "$chk" = ok ] && [ "$conv" = ok ]; then
      # Per-branch: a specialised round trip must validate wherever the
      # specialised original does.
      for v in true false; do
        local orig
        orig="$(classify_wax -i wat -f wasm -D "D=$v" "$base" -o /dev/null --validate)"
        [ "$orig" = ok ] || continue
        rt="$(classify_wax -i wax -f wasm -D "D=$v" "$wax" -o /dev/null --validate)"
        if [ "$rt" != ok ]; then
          out+="$(finding CONDFROMWASM HIGH "$(basename "$base") D=$v" \
            "specialised original validates but round trip gives '$rt'" "$(cat "$base")")"$'\n'
          printf F >&2
        fi
      done
    fi
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "converting $N conditional seeds (from_wasm) across $JOBS jobs (frozen wax)..." >&2
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
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== cond-fromwasm report ==================="
echo "seeds: $N"
echo "findings (over-rejection / crash / round-trip): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
