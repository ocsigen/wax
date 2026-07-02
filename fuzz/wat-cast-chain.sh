#!/usr/bin/env bash
#
# wat-cast-chain.sh
#
# A deterministic guard on the *WAT input* side, complementary to
# cast-lattice.sh (which drives the *Wax source* side). It builds WAT functions
# whose body is a chain of two cast / cast-like instructions that *make sense*
# — the classic shape being [(i31.get_s (ref.cast (ref i31) x))] — and asserts
# each such function round-trips through Wax with a *byte-identical* body.
#
# Why WAT-built chains. The decompiler fuses adjacent casts: the wasm pair
# [ref.cast (ref i31)] then [i31.get_s] decompiles to a single Wax [x as i32_s],
# and [to_wasm] must re-expand that one cast back into the two instructions. That
# fuse/re-expand seam is only exercised when the *input already contains the
# pair* — decompiling wasm the smith/corpus oracles feed rarely lines two casts
# up just so, and cast-lattice starts from Wax (one explicit cast per [as]), so
# it hits re-expansion but never the *decompiler's* fusion of a genuine wasm
# pair. Enumerating the pairs in WAT covers exactly that seam.
#
# Which pairs. Every cast-like instruction (numeric wrap/extend/trunc/convert/
# demote/promote/reinterpret/extendN, plus the reference casts ref.cast/ref.test/
# ref.i31/i31.get/ref.as_non_null/{any,extern}.convert) is tagged with the value
# type it consumes and the one it produces. We form every ordered pair whose
# types compose — the producer's result a subtype of the consumer's argument,
# under a small hand-rolled subtype relation over the numeric and GC-reference
# lattice (see [subtype]). Pairs that would not type-check are never emitted, so
# every generated function is valid wasm *by construction*; there is no
# "rejected is fine" bucket as in cast-lattice — here a rejection IS a finding
# (wax over-rejecting a module it built-and-accepts on the way in).
#
# Pruning the legitimately-canonicalised pairs. wax is *allowed* to rewrite a
# sequence to a canonical equivalent, which breaks a naive byte comparison
# against the original without being a bug — so we never emit those pairs:
#   * a [ref.cast] whose target is a supertype-or-equal of what the inner
#     instruction already produces is a proven no-op, and wax drops it (e.g.
#     [(ref.cast (ref any) (ref.cast (ref i31) x))] -> just [ref.cast (ref i31)]).
#     We skip a pair when the outer is a [ref.cast] and the inner's result is a
#     subtype of the outer's target (see [redundant_cast]). Dropping a provable
#     no-op cannot mask a bug — a no-op has no wrong answer.
#   * [i32.wrap_i64] then [i64.extend_i32_s] is exactly [i64.extend32_s], and
#     both decompile to the same Wax ([x as i32 as i64_s]); to_wasm canonicalises
#     that to the compact [i64.extend32_s], so the *explicit* pair does not
#     survive byte-for-byte. (The [i64.extend32_s] instruction itself round-trips
#     fine — it *is* the canonical form — so it stays in the set; only the
#     spelled-out equivalent is pruned.)
#
# The correctness oracle: byte-identity against the ORIGINAL binary. It is not
# enough to check the round-trip is a *fixed point* ([decompile.recompile] stable
# on its own output): a decompiler that misreads a pair in a self-consistent way
# (say [i31.get_s] as unsigned) would be stable yet wrong on the very first
# decompilation. So we anchor to a binary the decompiler never touched — the
# straight compile of the generated module:
#   orig = wat -> wasm
#   rt   = orig -> wax -> wasm       (i.e. wasm -> wax -> wasm)
# and assert orig and rt are byte-identical after [wasm-tools strip --all]
# removes the name section (the sole *legitimate* difference — the round-trip
# invents [$f]/[$x]/[$t] names the anonymous original lacks). The generated
# functions are deliberately shaped to sidestep the other benign
# non-determinisms the round-trip is allowed (per fuzz/README.md: local
# reordering, type dedup/renumber): they carry only params (no locals to
# reorder), and type dedup is applied identically on both sides. So byte-identity
# modulo names is a sound oracle *here* even though it is not one in general — a
# drift means the decompiler or [to_wasm] changed an instruction (a lost
# signedness, a dropped cast, a reordered chain), the exact bug class this hunts.
#
# Batching. Because every function is valid, there is no reason to isolate one
# per wax invocation the way cast-lattice must (it deliberately emits bad casts
# to hunt [assert false]). We pack MODULE_SIZE functions into one module and
# translate them together, so the whole sweep is a few dozen invocations, not a
# few hundred. When a batch fails, the worker bisects it — re-running each
# function alone — so every finding names the exact chain with a minimal,
# runnable repro.
#
# Exits non-zero if any chain crashes, is rejected, or fails to round-trip
# byte-identically, so it can gate CI. Deterministic. Needs wasm-tools (for
# [strip --all]); the round-trip legs themselves are wax-only.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v "$WASM_TOOLS" >/dev/null 2>&1; then
  echo "wat-cast-chain: wasm-tools not found (needed for 'strip --all'); set WASM_TOOLS or install it" >&2
  exit 2
fi

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
MODULE_SIZE="${MODULE_SIZE:-20}"   # functions batched into one module / round-trip
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# The WAT rendering of a wiring type token (the param/result type a chain is
# threaded through). The [refN_*] tokens are nullable [(ref null ht)], [ref_*]
# the non-null [(ref ht)].
type_wat() {
  case "$1" in
    i32) echo "i32" ;;  i64) echo "i64" ;;  f32) echo "f32" ;;  f64) echo "f64" ;;
    ref_any)     echo "(ref any)" ;;         refN_any)     echo "(ref null any)" ;;
    ref_eq)      echo "(ref eq)" ;;          refN_eq)      echo "(ref null eq)" ;;
    ref_i31)     echo "(ref i31)" ;;         refN_i31)     echo "(ref null i31)" ;;
    ref_struct)  echo "(ref struct)" ;;      refN_struct)  echo "(ref null struct)" ;;
    ref_extern)  echo "(ref extern)" ;;      refN_extern)  echo "(ref null extern)" ;;
  esac
}

# Heap-type subtyping over the fragment of the GC lattice the instructions
# below reach: i31 <: eq <: any and struct <: eq <: any (the [extern] hierarchy
# is disjoint from [any], so cross-family pairs never compose).
ht_subtype() {
  [ "$1" = "$2" ] && return 0
  case "$1|$2" in
    i31\|eq | i31\|any | struct\|eq | struct\|any | eq\|any) return 0 ;;
    *) return 1 ;;
  esac
}

# Does a value of wiring type $1 compose as the argument of an instruction
# expecting $2 — i.e. is $1 a subtype of $2? Numerics match only themselves; a
# nullable ref cannot flow where a non-null ref is required; otherwise defer to
# heap-type subtyping.
subtype() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 0
  case "$a" in i32 | i64 | f32 | f64) return 1 ;; esac
  case "$b" in i32 | i64 | f32 | f64) return 1 ;; esac
  local na hta nb htb
  case "$a" in refN_*) na=1 hta="${a#refN_}" ;; ref_*) na=0 hta="${a#ref_}" ;; esac
  case "$b" in refN_*) nb=1 htb="${b#refN_}" ;; ref_*) nb=0 htb="${b#ref_}" ;; esac
  [ "$na" = 1 ] && [ "$nb" = 0 ] && return 1
  ht_subtype "$hta" "$htb"
}

# The cast / cast-like instruction set: "label | consumes | produces | wat".
# [consumes]/[produces] are wiring-type tokens (above); [wat] is the folded
# opcode (with its immediate, for ref.cast/ref.test), threaded around its
# operand at build time. The consumes/produces types are each instruction's
# most general signature, so [subtype] over them enumerates exactly the pairs
# that type-check.
INSTRS=(
  # numeric conversions (wrap / extend / trunc / trunc_sat / convert)
  "i32.wrap_i64|i64|i32|i32.wrap_i64"
  "i64.extend_i32_s|i32|i64|i64.extend_i32_s"
  "i64.extend_i32_u|i32|i64|i64.extend_i32_u"
  "i32.trunc_f32_s|f32|i32|i32.trunc_f32_s"
  "i32.trunc_f64_u|f64|i32|i32.trunc_f64_u"
  "i64.trunc_f32_s|f32|i64|i64.trunc_f32_s"
  "i64.trunc_f64_u|f64|i64|i64.trunc_f64_u"
  "i32.trunc_sat_f32_s|f32|i32|i32.trunc_sat_f32_s"
  "i64.trunc_sat_f64_u|f64|i64|i64.trunc_sat_f64_u"
  "f32.convert_i32_s|i32|f32|f32.convert_i32_s"
  "f64.convert_i32_u|i32|f64|f64.convert_i32_u"
  "f32.convert_i64_s|i64|f32|f32.convert_i64_s"
  "f64.convert_i64_u|i64|f64|f64.convert_i64_u"
  "f32.demote_f64|f64|f32|f32.demote_f64"
  "f64.promote_f32|f32|f64|f64.promote_f32"
  # bit-preserving reinterpret casts
  "i32.reinterpret_f32|f32|i32|i32.reinterpret_f32"
  "f32.reinterpret_i32|i32|f32|f32.reinterpret_i32"
  "i64.reinterpret_f64|f64|i64|i64.reinterpret_f64"
  "f64.reinterpret_i64|i64|f64|f64.reinterpret_i64"
  # in-width sign extensions (i64.extend32_s has no dedicated Wax spelling — it
  # decompiles to a wrap+extend pair that to_wasm re-fuses back, so it too must
  # round-trip byte-identically)
  "i32.extend8_s|i32|i32|i32.extend8_s"
  "i32.extend16_s|i32|i32|i32.extend16_s"
  "i64.extend32_s|i64|i64|i64.extend32_s"
  # reference / GC casts and boxing
  "ref.i31|i32|ref_i31|ref.i31"
  "i31.get_s|refN_i31|i32|i31.get_s"
  "i31.get_u|refN_i31|i32|i31.get_u"
  "ref.as_non_null|refN_any|ref_any|ref.as_non_null"
  "ref.cast_i31|refN_any|ref_i31|ref.cast (ref i31)"
  "ref.cast_null_i31|refN_any|refN_i31|ref.cast (ref null i31)"
  "ref.cast_eq|refN_any|ref_eq|ref.cast (ref eq)"
  "ref.cast_any|refN_any|ref_any|ref.cast (ref any)"
  "ref.cast_struct|refN_any|ref_struct|ref.cast (ref struct)"
  "ref.cast_extern|refN_extern|ref_extern|ref.cast (ref extern)"
  "ref.test_i31|refN_any|i32|ref.test (ref i31)"
  "ref.test_eq|refN_any|i32|ref.test (ref eq)"
  "any.convert_extern|refN_extern|refN_any|any.convert_extern"
  "extern.convert_any|refN_any|refN_extern|extern.convert_any"
)

# Is outer instruction (label $1, produces $3) a [ref.cast] that is a proven
# no-op on a value of type $2 (what the inner instruction produces)? A ref.cast
# to a supertype-or-equal of the operand's static type casts nothing, and wax
# drops it — so such a pair would differ from the original without being a bug.
# For a ref.cast the produced token equals its target, so [subtype inner target]
# is the redundancy test.
redundant_cast() {
  case "$1" in ref.cast_*) ;; *) return 1 ;; esac
  subtype "$2" "$3"
}

# Build every type-composing ordered pair as "label<TAB>signature<TAB>body",
# where the body threads the outer instruction around the inner one:
#   (func <signature> (OUTER (INNER (local.get 0))))
# Pairs whose outer cast wax would drop as redundant are skipped (see the header
# and [redundant_cast]) so the byte-identity oracle sees no legitimate rewrite.
PAIRS=()
for A in "${INSTRS[@]}"; do
  IFS='|' read -r la ia oa wa <<<"$A"
  for B in "${INSTRS[@]}"; do
    IFS='|' read -r lb ib ob wb <<<"$B"
    subtype "$oa" "$ib" || continue
    redundant_cast "$lb" "$oa" "$ob" && continue
    # wax canonicalises i32.wrap_i64;i64.extend_i32_s to the equivalent
    # i64.extend32_s (they share the Wax form [x as i32 as i64_s]), so the
    # explicit pair does not round-trip byte-for-byte.
    { [ "$la" = i32.wrap_i64 ] && [ "$lb" = i64.extend_i32_s ]; } && continue
    PAIRS+=("$la >> $lb"$'\t'"(param $(type_wat "$ia")) (result $(type_wat "$ob"))"$'\t'"($wb ($wa (local.get 0)))")
  done
done
N=${#PAIRS[@]}

# Wrap a newline-separated list of "(func ...)" lines into a module.
module_of() { printf '(module\n%s)\n' "$1"; }

# One function's [(func ...)] text, from a PAIRS entry.
func_of() {
  local sig body
  IFS=$'\t' read -r _ sig body <<<"$1"
  printf '  (func %s\n    %s)\n' "$sig" "$body"
}

# Round-trip the WAT module at $1 and check byte-identity against its own
# straight compile. Prints "ok" on success, else the first failing step:
# a leg's non-ok classification ([crash:...]/[rejected]), or "diff (round-trip
# changed the module)". $2 is the per-worker scratch prefix for intermediates.
roundtrip() {
  local wat="$1" p="$2" v
  local orig="$p.orig.wasm" wax="$p.w.wax" rt="$p.rt.wasm"
  v="$(classify_wax -i wat -f wasm "$wat" -o "$orig")";  [ "$v" = ok ] || { echo "$v (wat->wasm)"; return; }
  v="$(classify_wax -i wasm -f wax "$orig" -o "$wax")";  [ "$v" = ok ] || { echo "$v (wasm->wax)"; return; }
  v="$(classify_wax -i wax -f wasm "$wax" -o "$rt")";    [ "$v" = ok ] || { echo "$v (wax->wasm)"; return; }
  # Strip name sections (the only legitimate difference) and compare the rest
  # byte-for-byte. A mismatch means the round-trip altered code or types.
  "$WASM_TOOLS" strip --all "$orig" -o "$orig.s" >/dev/null 2>&1
  "$WASM_TOOLS" strip --all "$rt"   -o "$rt.s"   >/dev/null 2>&1
  cmp -s "$orig.s" "$rt.s" && echo ok || echo "diff (round-trip changed the module)"
}

# Worker: round-trip the modules whose first pair index is in [first..last]
# stepping by MODULE_SIZE. A module that round-trips clean prints a dot; a
# failing one is bisected function-by-function so each finding names the exact
# chain and carries a one-line runnable repro.
chain_worker() {
  local first="$1" last="$2" i j out="" v
  local p="$RESULTS/w$first" wat="$RESULTS/w$first.wat"
  ERRLOG="$RESULTS/w$first.err"
  for ((i = first; i <= last; i += MODULE_SIZE)); do
    local end=$((i + MODULE_SIZE - 1)); [ "$end" -ge "$N" ] && end=$((N - 1))
    local funcs=""
    for ((j = i; j <= end; j++)); do funcs+="$(func_of "${PAIRS[$j]}")"; done
    module_of "$funcs" >"$wat"
    v="$(roundtrip "$wat" "$p")"
    if [ "$v" = ok ]; then printf . >&2; continue; fi
    # Batch failed: bisect to pin the culprit(s) to a single chain.
    for ((j = i; j <= end; j++)); do
      module_of "$(func_of "${PAIRS[$j]}")" >"$wat"
      v="$(roundtrip "$wat" "$p")"
      [ "$v" = ok ] && continue
      local label body; IFS=$'\t' read -r label _ body <<<"${PAIRS[$j]}"
      out+="$(finding CASTCHAIN HIGH "$label" "$v" "$body")"$'\n'
      printf F >&2
    done
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "enumerating $N cast chains in modules of $MODULE_SIZE across $JOBS jobs (frozen wax)..." >&2
# Give each worker a contiguous, module-aligned slice of the pair list.
mods=$(((N + MODULE_SIZE - 1) / MODULE_SIZE))
mods_per_job=$(((mods + JOBS - 1) / JOBS))
chunk=$((mods_per_job * MODULE_SIZE))
for ((w = 0; w * chunk < N; w++)); do
  first=$((w * chunk))
  last=$((first + chunk - 1)); [ "$last" -ge "$N" ] && last=$((N - 1))
  chain_worker "$first" "$last" &
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== wat-cast-chain report ==================="
echo "chains tested: $N"
echo "findings (crash, rejection, or non-identical round-trip): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
