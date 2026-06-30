#!/usr/bin/env bash
#
# smith.sh [count] [bytes]
#
# Generate `count` (default 200) guaranteed-valid wasm modules with
# `wasm-tools smith` and run every oracle on each. smith turns random bytes
# into a valid module, so it explores corners no hand-written corpus reaches —
# and because the module is valid by construction, EXPECT=valid: any rejection,
# crash, invalid emission, or broken round-trip is a real wax bug.
#
# `bytes` (default 2048) is how many random bytes seed each module; larger means
# bigger, more complex modules.
#
# Determinism: there is no Math.random() here — each module is seeded from
# /dev/urandom. Re-running explores fresh modules. A failing module's .wasm is
# preserved under the printed directory so it can be replayed with oracle.sh.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-200}"
BYTES="${2:-2048}"
KEEP="$ROOT/fuzz/smith-findings"
mkdir -p "$KEEP"
REPORT="$(mktemp)"
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"

# Enable the same bleeding-edge proposals wax targets, so smith generates the
# full language (GC, exceptions, stack switching, ...) rather than just the MVP.
SMITH_FLAGS=(--ensure-termination)

echo "generating + checking $COUNT modules ($BYTES seed bytes each)..."
nfind=0
for i in $(seq 1 "$COUNT"); do
  seed="$(mktemp)"; mod="$(mktemp --suffix=.wasm)"
  head -c "$BYTES" /dev/urandom >"$seed"
  if ! "$WASM_TOOLS" smith "${SMITH_FLAGS[@]}" "$seed" -o "$mod" 2>/dev/null; then
    rm -f "$seed" "$mod"; continue
  fi
  out="$(bash "$ORACLE" "$mod" valid)"
  if [ -n "$out" ]; then
    keep="$KEEP/smith-$i.wasm"
    cp "$mod" "$keep"
    # Rewrite the temp path in the report to the preserved copy.
    echo "${out//$mod/$keep}" >>"$REPORT"
    nfind=$((nfind+1))
  fi
  rm -f "$seed" "$mod"
  printf '\r%d/%d generated, %d with findings...' "$i" "$COUNT" "$nfind" >&2
done
echo >&2

echo "=================== smith report ==================="
echo "modules checked: $COUNT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null || echo 0)
echo "findings: $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo
  echo "failing modules saved under $KEEP/ — replay with:"
  echo "  bash fuzz/oracle.sh $KEEP/smith-<n>.wasm valid"
  echo
  echo "full report with reproduction commands: $REPORT"
fi
grep -q $'\tHIGH\t' "$REPORT" && exit 1
exit 0
