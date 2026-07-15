#!/usr/bin/env bash
#
# recover-fuzz.sh
#
# Stress the Wax panic-mode error recovery (Wax_conversion.Driver.wax_parse_recover,
# the in-process API a language server calls to collect *all* syntax errors plus
# a best-effort AST) for its two hard invariants: on any input it must always
# TERMINATE and never CRASH.
#
# Unlike the other oracles this one does not drive main.exe: parse_recover has no
# CLI surface, and a hang is best caught by a per-input watchdog inside the
# process. So the work is done by the fuzz_recover binary, which generates
# adversarial inputs (degenerate token piles, deep nesting, lexer-error garbage)
# and — when the valid corpus is present — mutations of real .wax files, running
# each under a TIMEOUT-second alarm. Its oracle: parse_recover must return without
# raising, within the budget; a raised exception or a hang is the bug, printed
# with the exact input for replay. Deterministic given SEED; exits non-zero iff a
# crash or hang was found.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ITERS="${ITERS:-50000}"                   # inputs per worker seed
WORKERS="${WORKERS:-4}"                    # distinct derived seeds
EXE="${RECOVER_EXE:-$ROOT/_build/default/src/bin/fuzz_recover.exe}"
CORPUS="${RECOVER_CORPUS:-$ROOT/fuzz/corpus-wax/valid}"  # optional; mutated if present

[ -x "$EXE" ] || { echo "fuzz_recover not built — run 'dune build' first" >&2; exit 2; }
announce_seed "bash $(basename "$0")"

corpus_arg=""
if [ -d "$CORPUS" ]; then corpus_arg="$CORPUS"; fi

status=0
for i in $(seq 0 $((WORKERS - 1))); do
  s=$((SEED + i))
  if ! TIMEOUT="$TIMEOUT" "$EXE" "$s" "$ITERS" $corpus_arg; then
    echo "FINDING: fuzz_recover crashed/hung at seed $s (replay: TIMEOUT=$TIMEOUT $EXE $s $ITERS $corpus_arg)" >&2
    status=1
  fi
done

[ "$status" -eq 0 ] && echo "recover-fuzz: no crash or hang across $WORKERS×$ITERS inputs."
exit "$status"
