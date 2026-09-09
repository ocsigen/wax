#!/usr/bin/env bash
#
# backing-scan.sh
#
# The RECONNECTION dimension of the width/ref-drift family: an exhaustive
# small-depth enumeration of the input space of [Stack.effective_backing] +
# [hole_claims] (from_wasm.ml), the hand-rolled simulation of the Wax
# re-parser that decides whether a dead reference op's bare hole needs a pin.
# Its founding finding (smith-468, fixed by 461d5aabea) was a MODELING
# divergence visible only on a three-entry stack: an extern residual, a
# two-hole statement claiming the values above it, and the [ref.is_null] hole
# — the scan read the statement as an opaque blocker, pinned as if
# bottom-sprung, and the pin became an [any.convert_extern] the source never
# had. No flat producer-x-consumer grid can see that: it is a property of the
# statement/residual SEQUENCE.
#
# What makes exhaustion possible is the scan's own abstraction: it never looks
# at opcodes, only at each entry's arity, width tag / recorded expectation,
# adaptivity, block shape, and hole-claim count. Its semantic input is a string
# over a small alphabet, so covering every abstract shape up to a depth bound
# covers, by proxy, every concrete stack whose abstraction fits in that depth —
# the scan cannot distinguish two members of one class. The alphabet below is
# READ OFF the scan's match arms, one concrete representative per class:
#
#   residuals   Rext extern-hierarchy ref     (extern.convert_any)
#               Rnull bare null               (ref.null extern)
#               Rfunc func-hierarchy ref      (ref.func)
#               Rany  any-hierarchy ref       (struct.new_default)
#               Rnum  width-TAGGED numeric    (i64.add)
#               Rmeth RECORDED-untagged num.  (f32.sqrt — the record path)
#               Rv128 recorded vector         (v128.not)
#               Radapt adaptive               (untyped select of holes)
#               Vmulti multi-value residual   (call returning two i64)
#               VmultiRE ref-carrying multi   (call returning i64 + externref)
#               VmultiRC as VmultiRE via call_ref (the type-named callee shape)
#               VmultiER ref-then-numeric multi (call returning externref + i64:
#               reconnection is positional, so the LAST result — here a
#               non-reference — is what the hole would capture)
#               RnullX exn-hierarchy null     (ref.null exn)
#               Rcont  cont-hierarchy ref     (cont.new)
#   statements  S0    no claim                (atomic.fence)
#               S0n   recorded-numeric hole   (local.set to an i64 local)
#               S1    one claim               (drop)
#               S2    two claims              (struct.set — the founding shape)
#               S3    three claims            (memory.copy)
#               Bp0   block, hole in own body (claims nothing here)
#               Bp1   block with a parameter  (claims one)
#               Bif   if — its condition hole (claims one)
#               T     terminator sentinel     (unreachable)
#               ScondPushEq/ScondPushNe/ScondPushR conditionals whose branch
#               PUSHES a value (equal i64 / then-only i64 / equal externref):
#               the spliced configurations see it on the enclosing frame, the
#               tree the lowering reads keeps it inside the branch block
#   composites  S1c/S2c a claiming statement WITH its claims satisfied by
#               adjacent values a blocking statement kept out of its grab —
#               the validator-forced spelling of the founding shape (see the
#               symbols below); S2c over an extern residual IS smith-468.
#
# and the READERS on top are the ops whose Wax surface erases their operand's
# hierarchy: ref.is_null (one hole), ref.eq (two), any.convert_extern (one),
# ref.test (one), and ref.cast (one; survival-exempt — a dead cast is by
# design absorbed, so only its validity/crash/no-introduced-crossing legs
# apply).
# MAINTENANCE: a new match arm in [effective_backing]/[statement_claims] must
# add its representative here (there is no mechanical table to derive this
# from — a pointer comment sits on the scan). The ScondEq/ScondNe symbols
# (conditional annotations) were once ACKNOWLEDGED wholesale as the known-open
# (@if) x dead-code corner (ATIF-DEADCODE.md's ~1400-finding set: conversion
# crashes plus reconnection drift under every claims model tried); the corner
# is fixed — the scan models the PRESERVED-tree typing (an annotation claims
# nothing; each branch is an isolated void block there), the spliced
# configuration passes mirror the source's own pops by construction, and a
# backing that provably re-types OUTSIDE what the reader's pin could ascribe
# gets the claim-free BOTTOM pin ([(_ as &?none)] and kin, which the typer
# gives no pending value) instead of a capturing top-of-hierarchy pin — and
# these cells are now ordinary calibration. Only (@if) can build the
# wrong-hierarchy-backing hazard: plain wasm's validator types the residual
# into the consumer and rejects.
#
# Every sequence of entries up to DEPTH (default 3; the founding bug sits at
# depth one via S2c, at two spelled out) is
# laid on the dead-code stack after [return], the reader on top. A cell the
# validator rejects is skipped (the cross-product over-generates; validity
# filters). A valid cell must round-trip wat -> wax -> wat in BOTH modes with
# (a) the reader's opcode surviving word-anchored — a vanished [ref.is_null]
# is the [i32.eqz] re-default — and (b) no hierarchy-crossing opcode
# INTRODUCED: each of any.convert_extern / extern.convert_any / ref.cast /
# ref.test may appear in the output at most as often as in the source (a pin
# that lowers to one IS the founding drift).
#
# Blast radius: dead-code FIDELITY (both modules validate; nothing executes).
# Calibration, both directions: against the binary before 461d5aabea it
# reports 414 findings, the founding shape [Rext.S2c.+isnull] among them; and
# its FIRST run against the then-current binary (with 461d5aabea already in)
# found 82 live findings in three fresh clusters of the same family, all fixed
# alongside this guard — the convert source pins never consulted the scan (a
# reconnectable extern/null leftover turned the pin into an introduced
# [ref.cast]), an all-numeric multi-value call residual read as a reference
# [`Backing], and a block-parameter claim double-counting the value [consume]
# had already taken. A third round came from interrogating the ALPHABET: the
# scan's verdict feeds callers that distinguish more than the scan does, so
# the symbols must cover the product of scan classes and caller-decision
# classes — a REF-carrying multi-value residual (VmultiRE/VmultiRC, absent
# from the first alphabet) predicted and confirmed a live convert drift, 1432
# findings on the pre-fix binary once the trailing [unreachable] sink let
# those cells validate (concrete leftovers fail the end-of-frame check even in
# dead code — without the sink the cells were silently skipped and the
# calibration reported a hollow 0: always confirm a new symbol's cells appear
# in the TESTED count). 0 findings on the fixed binary. Deterministic,
# parallel, wax-only. Tests the binary [_build] holds — run [dune build]
# first.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 2 ))}"
DEPTH="${DEPTH:-3}"
# SYMS=core keeps one representative per SCAN-equivalence-class (dropping the
# caller-class duplicates: the extra hierarchies, the recorded-numeric
# variants, the call_ref spelling, claim counts beyond two, the unequal
# conditional). Depth 4 over the full alphabet is ~1.4M cells; over the core
# it is the nightly's deeper lane.
SYMS="${SYMS:-all}"
# The acknowledged-net ratchet (see exempt_shape below): the measured
# over-rejection count inside the net for each standard lane, counted per
# conversion MODE (one red cell = two findings, default + --faithful). Growth
# past the baseline fails the run — the net is a name PATTERN, wider than its
# red cells, and must not silently absorb new ones. An ad-hoc lane runs
# unratcheted (-1 = report only); override with ACK_RED_MAX=n.
case "$DEPTH/$SYMS" in
3/all) ACK_DEF=4 ;;
4/core) ACK_DEF=0 ;;
*) ACK_DEF=-1 ;;
esac
ACK_RED_MAX="${ACK_RED_MAX:-$ACK_DEF}"
CORE="Rext Rnull Rnum Radapt Vmulti VmultiRE S0 S0n S1 S2c Bp1 Bif T ScondEq ScondPushEq"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- The alphabet: name -> wat lines (| separates instructions). ----
declare -a E_NAME E_CODE
sym() { E_NAME+=("$1"); E_CODE+=("$2"); }
sym Rext   "extern.convert_any"
sym Rnull  "ref.null extern"
sym Rfunc  "ref.func \$f"
sym Rany   "struct.new_default \$s"
sym Rnum   "i64.add"
sym Rmeth  "f32.sqrt"
sym Rv128  "v128.not"
sym Radapt "select"
sym Vmulti "call \$f2"
sym VmultiRE "call \$f3"
sym VmultiRC "call_ref \$ft3"
sym VmultiER "call \$f4"
sym RnullX "ref.null exn"
sym Rcont  "cont.new \$ct"
sym S0     "atomic.fence"
sym S0n    "local.set \$l64"
sym S1     "drop"
sym S2     "struct.set \$s 0"
sym S3     "memory.copy"
sym Bp0    "block|drop|end"
sym Bp1    "block (param externref)|drop|end"
sym Bif    "if|end"
sym T      "unreachable"
# The SATISFIED-claims composites. The validator types dead code, so a claiming
# statement laid directly on a residual CONSUMES it — the founding shape needs
# its claims satisfied by values whose grab a statement then blocks: the values
# stay residuals in the model, the statement's operands become holes, and on
# the re-parse the holes claim those very values back. Encoding that forced
# composition as one symbol keeps the founding bug (smith-468: S2c over an
# extern residual) at depth ONE instead of the five entries it spells out to.
sym S1c    "i64.const 1|atomic.fence|drop"
sym S2c    "struct.new_default \$s|i64.const 1|atomic.fence|struct.set \$s 0"
# The conditional-annotation statements. The typer scopes a branch's holes to
# the branch and from_wasm runs the bodies on fresh stacks, so an annotation
# claims NOTHING from this stack whatever its branches hold — one symbol with
# an else, one without, to pin both spellings.
sym ScondEq "(@if \$dbg (@then drop) (@else drop))"
sym ScondNe "(@if \$dbg (@then drop))"
# The PUSHING conditionals: a branch that leaves a value on the enclosing
# frame (per configuration, in the spliced validation), where the tree the
# lowering reads keeps it inside the branch block. One numeric pair
# (equal/unequal push) and one reference push.
sym ScondPushEq "(@if \$dbg (@then i64.const 1) (@else i64.const 1))"
sym ScondPushNe "(@if \$dbg (@then i64.const 1))"
sym ScondPushR "(@if \$dbg (@then ref.null extern) (@else ref.null extern))"

if [ "$SYMS" = core ]; then
  declare -a KN KC
  for i in "${!E_NAME[@]}"; do
    case " $CORE " in
      *" ${E_NAME[$i]} "*) KN+=("${E_NAME[$i]}"); KC+=("${E_CODE[$i]}") ;;
    esac
  done
  E_NAME=("${KN[@]}"); E_CODE=("${KC[@]}")
fi

declare -a R_NAME R_CODE R_OP R_SURV
rdr() { R_NAME+=("$1"); R_OP+=("$2"); R_CODE+=("$3"); R_SURV+=("${4:-1}"); }
rdr isnull "ref.is_null"        "ref.is_null|drop"
rdr refeq  "ref.eq"             "ref.eq|drop"
rdr cvt    "any.convert_extern" "any.convert_extern|drop"
rdr test   "ref.test"           "ref.test (ref null \$s)|drop"
# A dead [ref.cast] is BY DESIGN absorbed on the round trip (its hole
# reconnects, or its bottom-sprung pin folds; the compiler-cast family the
# FAITHDRIFT leg normalises away), so its survival leg is exempt (0): the
# cells still assert validity, no crash, and no INTRODUCED crossing — the
# output may carry at most the source's one ref.cast.
rdr cast   "ref.cast"           "ref.cast (ref null \$s)|drop" 0

# The crossing opcodes that must not be INTRODUCED (output count <= source
# count, per opcode).
CROSSERS=(any.convert_extern extern.convert_any ref.cast ref.test)

# The one ACKNOWLEDGED residue of the (@if) x dead-code campaign: a value
# residual BELOW a REF-pushing conditional that feeds a parameterized block.
# There [Stack.consume] must inject its synthetic (else the tree the lowering
# reads captures and re-types the residual through the parameter claim), the
# parameter then takes the synthetic in every configuration, and the branch's
# push is left stranded onto whatever claimer follows. When the claimer's
# hierarchy cannot absorb the push, the spliced validation rejects —
# over-REJECTION only, and loud; no crash and no silent miscompile is in the
# class. With NOTHING below the annotation the synthetic is no longer injected
# and those cells are ordinary calibration — see ATIF-DEADCODE.md.
# (The former Radapt exemption — a select's arm holes claiming across the
# annotation — was retired when the arms gained claim-free type ascriptions.)
# The net is CALIBRATED, not skipped: exempt cells are tested like any other,
# a clean wat->wax over-rejection there is expected (severity ACK, ratcheted
# by ACK_RED_MAX above), and every other outcome stays HIGH.
exempt_shape() { # $1 = cell name
  case "$1" in
  *.*ScondPush*.Bp1.*) return 0 ;;
  *) return 1 ;;
  esac
}

template() { # $1 = |-separated instruction list
  local body
  body="$(printf '%s' "$1" | tr '|' '\n' | sed 's/^/    /')"
  cat <<EOF
(module
  (type \$s (struct (field (mut i64))))
  (memory 1 1 shared)
  (elem declare func \$f)
  (func \$f (result i64) (i64.const 1))
  (func \$f2 (result i64 i64) (i64.const 1) (i64.const 2))
  (type \$ft0 (func (result i64)))
  (type \$ct (cont \$ft0))
  (type \$ft3 (func (result i64 externref)))
  (func \$f3 (result i64 externref) (i64.const 1) (ref.null extern))
  (func \$f4 (result externref i64) (ref.null extern) (i64.const 1))
  (func (local \$l64 i64)
    return
$body))
EOF
}

# ---- Enumerate sequences of length 0..DEPTH, each under each reader. ----
NSYM=${#E_NAME[@]}
COMBOS=()
gen() { # $1 = remaining depth, $2 = name path, $3 = code path
  local r
  for r in "${!R_NAME[@]}"; do
    COMBOS+=("$2+${R_NAME[$r]}"$'\t'"$r"$'\t'"$3")
  done
  [ "$1" -eq 0 ] && return
  local i
  for i in $(seq 0 $((NSYM - 1))); do
    gen $(($1 - 1)) "$2${E_NAME[$i]}." "$3${E_CODE[$i]}|"
  done
}
gen "$DEPTH" "" ""
N=${#COMBOS[@]}

count_ops() { # $1 = file, $2 = opcode; occurrences, word-anchored
  grep -oE "${2//./\\.}([^0-9a-z_.]|\$)" "$1" 2>/dev/null | wc -l
}

worker() {
  local first="$1" last="$2" i name ridx codes v mode out="" skipped=0 acked=0
  local p="$RESULTS/w$first"
  local wax="$p.wax" back="$p.back.wat"
  local dir="$p.cells"
  mkdir -p "$dir"
  ERRLOG="$p.err"
  # ---- Batched validity pre-filter. Two thirds of the cells are invalid and
  # exist only to be skipped, and discovering that cost one process spawn per
  # cell — the dominant share of a run's wall clock. [wax check] takes many
  # files at once and prefixes each [--error-format short] diagnostic with its
  # path, so one process filters a whole chunk. Two fallbacks keep the
  # per-cell classification's guarantees: a batch that CRASHES (a cell that
  # kills the checker would take its chunkmates' verdicts with it), and the
  # SYNTAX-abort signature — a parse error stops a multi-file check midway,
  # with exit 0, leaving the rest unchecked (template output is never
  # syntactically invalid, so this is belt-and-braces) — both re-check that
  # chunk file by file.
  declare -A BAD
  local -a chunk=()
  flush_chunk() {
    [ ${#chunk[@]} -eq 0 ] && return 0
    local bout rc f errs=0
    bout=$(NO_COLOR=1 timeout -k 5 $((TIMEOUT * 10)) \
      "$WAX" check --error-format short "${chunk[@]}" 2>&1)
    rc=$?
    while IFS= read -r line; do
      case "$line" in
        "$dir"/*.wat:*" error: "*)
          errs=1
          f="${line%%.wat:*}.wat"
          BAD["$f"]=1
          ;;
      esac
    done <<<"$bout"
    if { [ "$rc" -ne 0 ] && [ "$rc" -ne 128 ]; } \
      || { [ "$rc" -eq 0 ] && [ "$errs" -eq 1 ]; }; then
      for f in "${chunk[@]}"; do
        unset "BAD[$f]"
        [ "$(classify_wax check "$f")" != ok ] && BAD["$f"]=1
      done
    fi
    chunk=()
    return 0
  }
  for ((i = first; i <= last; i++)); do
    local rest="${COMBOS[$i]#*$'\t'}"
    ridx="${rest%%$'\t'*}"
    codes="${rest#*$'\t'}${R_CODE[$ridx]}|unreachable"
    template "$codes" >"$dir/$i.wat"
    chunk+=("$dir/$i.wat")
    [ ${#chunk[@]} -ge 200 ] && flush_chunk
  done
  flush_chunk
  for ((i = first; i <= last; i++)); do
    name="${COMBOS[$i]%%$'\t'*}"
    local rest="${COMBOS[$i]#*$'\t'}"
    ridx="${rest%%$'\t'*}"
    local wat="$dir/$i.wat"
    # The trailing [unreachable] absorbs whatever the cell leaves on the
    # stack (concrete leftovers fail the end-of-frame check even in dead
    # code, which silently skipped every cell whose residuals outlive the
    # reader — the ref-multi calibration found the hole). Symmetric in the
    # opcode comparison, after the reader, so inert to the oracle.
    codes="${rest#*$'\t'}${R_CODE[$ridx]}|unreachable"
    if [ -n "${BAD[$wat]:-}" ]; then
      rm -f "$wat"
      skipped=$((skipped + 1)); printf s >&2; continue
    fi
    local sev=HIGH
    if exempt_shape "$name"; then
      # The calibration leg over the acknowledged net: a clean wat->wax
      # over-rejection is the class's one documented failure, so it reports
      # at ACK and counts against the ratchet instead of failing outright.
      # Anything else on an exempt cell — a crash, output that fails to
      # recompile, reader drift, an introduced crossing — stays HIGH: the
      # name-pattern net must not hide a regression that lands inside it.
      sev=ACK
      acked=$((acked + 1))
    fi
    for mode in "" "--faithful"; do
      v="$(classify_wax -i wat -f wax $mode --error-format short "$wat" -o "$wax")"
      if [ "$v" != ok ]; then
        if [ "$sev" = ACK ] && [ "$v" = rejected ]; then
          out+="$(finding BACKSCAN ACK "$name" \
            "${mode:-default}: $v (wat->wax): $(head -1 "$ERRLOG")" "$codes")"$'\n'
          printf x >&2; continue
        fi
        out+="$(finding BACKSCAN HIGH "$name" \
          "${mode:-default}: $v (wat->wax): $(head -1 "$ERRLOG")" "$codes")"$'\n'
        printf F >&2; continue
      fi
      v="$(classify_wax -i wax -f wat "$wax" -o "$back")"
      if [ "$v" != ok ]; then
        out+="$(finding BACKSCAN HIGH "$name" \
          "${mode:-default}: $v (wax->wat): $(head -1 "$ERRLOG")" "$codes")"$'\n'
        printf F >&2; continue
      fi
      if [ "${R_SURV[$ridx]}" = 1 ] \
        && ! grep -qE "${R_OP[$ridx]//./\\.}([^0-9a-z_.]|\$)" "$back"; then
        out+="$(finding BACKSCAN HIGH "$name" \
          "${mode:-default}: reader opcode (${R_OP[$ridx]}) drifted" "$codes")"$'\n'
        printf F >&2; continue
      fi
      local x bad=""
      for x in "${CROSSERS[@]}"; do
        if [ "$(count_ops "$back" "$x")" -gt "$(count_ops "$wat" "$x")" ]; then
          bad="$x"; break
        fi
      done
      if [ -n "$bad" ]; then
        out+="$(finding BACKSCAN HIGH "$name" \
          "${mode:-default}: crossing opcode introduced ($bad)" "$codes")"$'\n'
        printf F >&2; continue
      fi
    done
    rm -f "$wat"
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
  [ "$skipped" -gt 0 ] && printf '%s\n' "$skipped" >"$RESULTS/skip.$first"
  [ "$acked" -gt 0 ] && printf '%s\n' "$acked" >"$RESULTS/ack.$first"
  return 0
}

echo "backing-scan: $N stack-shape cells (depth <= $DEPTH, ${#E_NAME[@]} symbols, ${#R_NAME[@]} readers) across $JOBS jobs..." >&2
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
n=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); n=${n:-0}
ackr=$(grep -c $'\tACK\t' "$REPORT" 2>/dev/null); ackr=${ackr:-0}
skipped=$(cat "$RESULTS"/skip.* 2>/dev/null | paste -sd+ | bc 2>/dev/null); skipped=${skipped:-0}
acked=$(cat "$RESULTS"/ack.* 2>/dev/null | paste -sd+ | bc 2>/dev/null); acked=${acked:-0}
if [ "$ACK_RED_MAX" -ge 0 ]; then ackmsg="$ackr of max $ACK_RED_MAX"; else ackmsg="$ackr, unratcheted"; fi
echo "=================== backing-scan report ==================="
echo "cells: $N  tested: $((N - skipped))  (skipped as invalid: $skipped; acknowledged net: $acked cells, over-rejections: $ackmsg)"
echo "findings: $n  (HIGH: $n)"
if [ "$n" -gt 0 ] || { [ "$ACK_RED_MAX" -ge 0 ] && [ "$ackr" -gt "$ACK_RED_MAX" ]; }; then
  cat "$REPORT"
  [ "$ACK_RED_MAX" -ge 0 ] && [ "$ackr" -gt "$ACK_RED_MAX" ] \
    && echo "acknowledged net grew: $ackr over-rejections > baseline $ACK_RED_MAX"
  exit 1
fi
exit 0
