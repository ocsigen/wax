# Shared configuration and helpers for the wax fuzzing harness.
# Sourced by the other fuzz/*.sh scripts; not executed directly.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAX="${WAX:-$ROOT/_build/default/src/bin/main.exe}"
WASM_TOOLS="${WASM_TOOLS:-wasm-tools}"
TIMEOUT="${TIMEOUT:-30}"        # seconds per wax invocation; longer counts as a hang
# wax targets bleeding-edge proposals (stack switching, GC, ...). Validate the
# reference against the same feature set, or it rejects valid wax output for a
# proposal it has merely defaulted off.
WT_FEATURES="${WT_FEATURES:-all}"

# Flags for `wasm-tools smith` (shared by smith.sh and wax-corpus.sh). Enable the
# bleeding-edge proposals wax targets (GC, exceptions, stack switching, ...) but
# disable threads/atomics — the 0xFE opcodes are not implemented by wax, so they
# only add one noisy "illegal opcode fe" signature.
SMITH_FLAGS="${SMITH_FLAGS:---ensure-termination --threads-enabled false --shared-everything-threads-enabled false}"

# Locate wasm-tools, falling back to the usual cargo location.
if ! command -v "$WASM_TOOLS" >/dev/null 2>&1; then
  if [ -x "$HOME/.cargo/bin/wasm-tools" ]; then
    WASM_TOOLS="$HOME/.cargo/bin/wasm-tools"
  fi
fi

# Run wax under a timeout and classify the exit status into one bucket, printed
# on stdout: ok | rejected | crash:<detail>. The whole command line is passed in.
#   ok        — exit 0 (accepted / converted)
#   rejected  — a clean "no": 128 (located validation diagnostic), 123 (parse /
#               malformed-input error). Both are intended answers, not bugs.
#   crash:... — anything else: cmdliner internal error from an uncaught
#               exception (125), a bare uncaught exception (2), a signal,
#               a timeout (124), or any unexpected code. These are the bugs.
classify_wax() {
  timeout -k 5 "$TIMEOUT" "$WAX" "$@" >/dev/null 2>"$ERRLOG"
  local code=$?
  case $code in
    0)       echo ok ;;
    123|128) echo rejected ;;
    124)     echo "crash:timeout(${TIMEOUT}s)" ;;
    2|125)   echo "crash:uncaught-exception(exit $code)" ;;
    13[2-9]|140) echo "crash:signal($((code-128)))" ;;
    *)       echo "crash:exit($code)" ;;
  esac
  return 0
}

# Validate a binary with the reference, all proposals enabled. Returns its exit
# status; the message (if any) is left in $1.err for the caller to quote.
wt_validate() {
  "$WASM_TOOLS" validate --features "$WT_FEATURES" "$1" >"$1.err" 2>&1
}

# Detect a file's format from its extension (wat | wasm | wax).
fmt_of() {
  case "$1" in
    *.wat)  echo wat ;;
    *.wasm) echo wasm ;;
    *.wax)  echo wax ;;
    *)      echo "" ;;
  esac
}

# Emit a finding. Columns are tab-separated so run.sh can sort/aggregate:
#   CATEGORY  SEVERITY  INPUT  DETAIL  REPRO
# SEVERITY is HIGH (wax emits/accepts wrong) or REVIEW (needs a human look).
finding() {
  printf 'FINDING\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
}
