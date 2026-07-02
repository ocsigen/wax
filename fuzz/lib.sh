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
# bleeding-edge proposals wax targets (GC, exceptions, stack switching, threads /
# atomics, ...). [shared-everything-threads] stays off — that is a separate, newer
# proposal wax does not implement (it would only add noise).
SMITH_FLAGS="${SMITH_FLAGS:---ensure-termination --threads-enabled true --shared-everything-threads-enabled false}"

# Master seed for reproducible mutation campaigns. Each mutator (fuzz_mutate,
# mutate-wasm.js, mutate-wat.awk) is deterministic given an integer seed; the
# campaigns below derive every per-mutation seed from $SEED and the mutant index
# (see the workers), so a whole run replays from this one number. Left unset it
# is chosen here and announced by the campaign (announce_seed) so any run — even
# one that stumbled on a finding by luck — can be reproduced with SEED=<n>.
SEED="${SEED:-$((RANDOM * 32768 + RANDOM))}"

# Announce the master seed and how to replay. Call once at a campaign's start,
# passing the campaign's own invocation for the hint.
announce_seed() { echo "master seed $SEED  (replay with: SEED=$SEED $*)" >&2; }

# Locate wasm-tools, falling back to the usual cargo location.
if ! command -v "$WASM_TOOLS" >/dev/null 2>&1; then
  if [ -x "$HOME/.cargo/bin/wasm-tools" ]; then
    WASM_TOOLS="$HOME/.cargo/bin/wasm-tools"
  fi
fi

# Snapshot the wax binary and repoint $WAX at the copy. A long parallel campaign
# fans hundreds of short wax invocations across workers; if the developer rebuilds
# `_build/.../main.exe` while it runs, a worker can exec a half-written binary and
# get a spurious non-zero exit, which the crash oracles then report as a bug (a
# whole burst of them). Running against a frozen copy makes a campaign immune to
# concurrent rebuilds. Pass the run's scratch dir so the copy is removed with it;
# call once, before exporting WAX to the workers. Idempotent.
freeze_wax() {
  [ -n "${WAX_FROZEN:-}" ] && return 0
  if [ ! -x "$WAX" ]; then
    echo "freeze_wax: wax not found or not executable at $WAX (run 'dune build')" >&2
    return 1
  fi
  local frozen
  # A dotfile name when placed in the run's scratch dir: the report collectors
  # glob [$RESULTS/*] (which skips dotfiles), so the binary snapshot is never
  # slurped into a findings report, while [rm -rf $RESULTS] still removes it.
  if [ -n "${1:-}" ]; then frozen="$1/.wax-frozen"; else frozen="$(mktemp)"; fi
  cp "$WAX" "$frozen" && chmod +x "$frozen"
  WAX="$frozen"
  WAX_FROZEN="$frozen"
}

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
