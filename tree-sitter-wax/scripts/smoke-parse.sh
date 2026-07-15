#!/usr/bin/env bash
# Parse every curated .wax file and assert zero ERROR/MISSING nodes, except for
# the syntactically-invalid fixtures listed in test/expected-errors.txt, which
# must produce an error (negative tests).
#
# Corpus:
#   - build/doc-blocks/**   (complete programs from docs/src/examples.md)
#   - test/cram-tests/**/*.wax   (hand-written fixtures; `bad*.wax` are usually
#     *semantic* errors that must still parse cleanly)
# Excluded: fuzz mutants (`mutant-*`, `*findings*`) and _build/ artifacts,
# which are frequently syntactically invalid by construction. Doc fragments
# (cheatsheet / most of language.md) illustrate syntax pieces rather than whole
# modules, so only examples.md — whole programs — is extracted for the corpus.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"

"$here/scripts/extract-doc-blocks.sh" >/dev/null

# Expected-error set (repo-relative paths → absolute).
declare -A expect_error=()
while IFS= read -r line; do
  line="${line%%#*}"; line="${line// /}"
  [ -n "$line" ] && expect_error["$repo/$line"]=1
done < "$here/test/expected-errors.txt"

roots=("$here/build/doc-blocks")
[ -d "$repo/test/cram-tests" ] && roots+=("$repo/test/cram-tests")
[ -d "$repo/test/wasmoo/wax" ] && roots+=("$repo/test/wasmoo/wax")

mapfile -t files < <(
  find "${roots[@]}" -name '*.wax' 2>/dev/null \
    | grep -vE '(/_build/|mutant-|findings)' \
    | sort
)

# Only whole-program doc examples are known-good; fragments illustrate pieces.
keep_doc='doc-blocks/examples-'

total=0 clean_fail=0 neg_fail=0
for f in "${files[@]}"; do
  case "$f" in
    */build/doc-blocks/*)
      [[ "$f" == *"$keep_doc"* ]] || continue ;;
  esac
  total=$((total + 1))
  if npx --no-install tree-sitter parse -q "$f" >/dev/null 2>&1; then
    if [ -n "${expect_error[$f]:-}" ]; then
      neg_fail=$((neg_fail + 1))
      echo "UNEXPECTED CLEAN (should error): $f"
    fi
  else
    if [ -z "${expect_error[$f]:-}" ]; then
      clean_fail=$((clean_fail + 1))
      echo "ERROR: $f"
    fi
  fi
done

echo "---"
echo "Parsed $total file(s); $clean_fail unexpected error(s), $neg_fail negative-test regression(s)."
[ "$clean_fail" -eq 0 ] && [ "$neg_fail" -eq 0 ]
