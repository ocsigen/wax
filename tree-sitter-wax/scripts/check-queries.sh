#!/usr/bin/env bash
# Compile every tree-sitter query in the repository against THIS grammar.
#
# A query naming a node or token the grammar does not have fails to compile, and
# the host then loses the whole feature (Helix disables highlighting for the
# language; Emacs signals on the font-lock rules). Nothing else in CI notices, so
# a query copy can rot for a whole release cycle after a keyword is removed —
# which is exactly what happened to the stack-switching keywords once `resume` &
# co. became method calls. This check is the guard.
#
# Covered: the package's own queries/, the Helix query set, and the token lists
# the Emacs mode splices into its font-lock queries (elisp, so token names are
# checked against the grammar's literals rather than compiled).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"

export TREE_SITTER_DIR="$here/build/tree-sitter"
export TREE_SITTER_LIBDIR="$TREE_SITTER_DIR/lib"
mkdir -p "$TREE_SITTER_LIBDIR"
printf '{ "parser-directories": ["%s"] }\n' "$repo" > "$TREE_SITTER_DIR/config.json"

sample="$TREE_SITTER_DIR/sample.wax"
printf 'fn f() { nop; }\n' > "$sample"

failed=0

for q in "$here"/queries/*.scm "$repo"/editors/helix/queries/wax/*.scm; do
  [ -e "$q" ] || continue
  if out=$(cd "$here" && npx --no-install tree-sitter query "$q" "$sample" 2>&1 >/dev/null); then
    :
  else
    failed=$((failed + 1))
    echo "QUERY FAILED: ${q#$repo/}"
    echo "$out" | grep -E "Invalid|error" | head -3
  fi
done

# The Emacs mode builds its keyword query from two elisp lists; every entry has
# to be an anonymous token of the grammar.
el="$repo/editors/emacs/wax-ts-mode.el"
if [ -e "$el" ]; then
  node -e '
    const fs = require("fs");
    const [gj, el] = process.argv.slice(1);
    const lits = new Set();
    (function walk(x) {
      if (Array.isArray(x)) x.forEach(walk);
      else if (x && typeof x === "object") {
        if (x.type === "STRING") lits.add(x.value);
        Object.values(x).forEach(walk);
      }
    })(JSON.parse(fs.readFileSync(gj, "utf8")));
    const src = fs.readFileSync(el, "utf8");
    let bad = [];
    for (const name of ["keywords", "modifiers"]) {
      const m = src.match(new RegExp("wax-ts-mode--" + name + "\\s*\\n\\s*\x27\\(([^)]*)\\)", "s"));
      if (!m) { console.log("MISSING LIST: wax-ts-mode--" + name); process.exitCode = 1; continue; }
      for (const t of m[1].match(/"[^"]*"/g) || []) {
        const tok = t.slice(1, -1);
        if (!lits.has(tok)) bad.push(name + ": " + tok);
      }
    }
    if (bad.length) {
      console.log("EMACS TOKENS NOT IN GRAMMAR:");
      bad.forEach((b) => console.log("  " + b));
      process.exitCode = 1;
    }
  ' "$here/src/grammar.json" "$el" || failed=$((failed + 1))
fi

echo "---"
if [ "$failed" -eq 0 ]; then
  echo "All queries compile against the grammar."
else
  echo "$failed query set(s) do not match the grammar."
fi
[ "$failed" -eq 0 ]
