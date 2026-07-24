# wat-null-mutate.awk — apply ONE type-preserving bottom-value mutation to an
# UNFOLDED WAT module (wax `--unfold` output), for null-mutate.sh. `-v k=N` picks
# the mutation site (0-based); `-v count=1` instead prints the number of sites.
# Reads WAT on stdin (or a file arg), writes the mutant to stdout.
#
# The metamorphic idea (paired driver null-mutate.sh): the recent round-trip bugs
# were compositions of a bottom-typed value with a type-adaptive surface, so
# INJECTING such values into a known-valid module — where the surrounding surfaces
# are real, intertwined code the generators never produce — and round-tripping the
# result is a sharp net. Three mutations, each keyed on a producer line whose
# result type is SELF-EVIDENT from the line itself (so no scope resolution is
# needed and the rewrite is type-correct by construction):
#
#   NULL   (a) — replace a reference operand with a `ref.null` at a matching
#                bottom/abstract heap type: a `ref.func` becomes `ref.null nofunc`;
#                a `ref.null HT` is re-pointed to the bottom of HT's hierarchy
#                (func/$funcT -> nofunc, extern -> noextern, any/eq/i31/struct/
#                array/$aggT -> none). This changes the value's precise type /
#                nullability, so the mutant may or may not stay valid — the
#                reference interpreter arbitrates (both-reject = INSERTER, not a
#                wax bug), exactly as unreachable-fuzz.sh does.
#   SELECT (b) — wrap a value in `select v v (i32.const 1)`, which returns v
#                unchanged (condition is nonzero): metamorphic, value- AND
#                type-preserving. Untyped for a numeric const, typed
#                `select (result (ref null HT))` for a `ref.null HT`. A valid
#                mutant by construction, so its round-trip MUST stay valid.
#   BRNULL (c) — route a nullable ref through a `br_on_null`-family passthrough
#                inside a block, semantics-preserving:
#                    block $l (result (ref null HT))
#                      <the ref.null HT>
#                      br_on_non_null $l    ;; non-null: exit with the value
#                      ref.null HT          ;; null path: reconstruct the null
#                    end
#                so the block yields the original value on both paths. Exercises
#                from_wasm's br_on_null/br_on_non_null decompilation on a real body.
#
# Every mutation preserves the instruction's net stack arity (one value out) and
# introduces no numeric-label shift (the BRNULL block opens and closes in place),
# so the module stays structurally well-formed; only NULL deliberately perturbs
# the type, for the reference to judge. Keying on the self-evident producers
# (`ref.null`, `ref.func`, `iNN/fNN.const`) keeps the mutator correct with no WAT
# type inference; the corpus carries these in abundance (decompiled GC/reference
# modules).

{ arr[NR] = $0; nl = NR }

# Build a heap-type-kind map from the type section so NULL can pick the right
# bottom for a concrete `$t` (func/cont -> nofunc, struct/array -> none).
/\(type[ \t]+\$[^ \t()]+[ \t]*\((struct|array|func|cont)\b/ {
  line = $0
  while (match(line, /\(type[ \t]+\$[^ \t()]+[ \t]*\((struct|array|func|cont)/)) {
    seg = substr(line, RSTART, RLENGTH)
    match(seg, /\$[^ \t()]+/); nm = substr(seg, RSTART, RLENGTH)
    kind[nm] = (seg ~ /\((func|cont)$/) ? "func" : "agg"
    line = substr(line, RSTART + RLENGTH)
  }
}

function bottom(ht) {
  if (ht == "func" || ht == "nofunc") return "nofunc"
  if (ht == "extern" || ht == "noextern") return "noextern"
  if (ht == "exn" || ht == "noexn") return "noexn"
  if (ht ~ /^\$/) return (kind[ht] == "func") ? "nofunc" : "none"
  return "none"   # any/eq/i31/struct/array/none and unknowns
}

function indent_of(s,   w) { w = s; sub(/[^ \t].*$/, "", w); return w }

# Register a site: line index, mutation kind, heap type (for ref forms).
function site(i, knd, ht) { sI[ns] = i; sK[ns] = knd; sH[ns] = ht; ns++ }

END {
  ns = 0
  for (i = 1; i <= nl; i++) {
    l = arr[i]
    body = l; sub(/^[ \t]+/, "", body)
    if (body ~ /^ref\.null[ \t]+[^ \t()]+[ \t]*$/) {
      ht = body; sub(/^ref\.null[ \t]+/, "", ht); sub(/[ \t]+$/, "", ht)
      if (bottom(ht) != ht) site(i, "NULL", ht)   # skip a no-op re-point
      site(i, "SELECT", ht)
      site(i, "BRNULL", ht)
    } else if (body ~ /^ref\.func([ \t]|$)/) {
      site(i, "NULL", "")
    } else if (body ~ /^(i32|i64|f32|f64)\.const([ \t]|$)/) {
      site(i, "SELECT", "")
    }
  }

  if (count) { print ns + 0; exit }
  if (ns == 0) { for (i = 1; i <= nl; i++) print arr[i]; exit }

  k = (k % ns + ns) % ns
  ti = sI[k]; tk = sK[k]; th = sH[k]
  ind = indent_of(arr[ti])

  for (i = 1; i <= nl; i++) {
    if (i != ti) { print arr[i]; continue }
    if (tk == "NULL") {
      if (th == "") print ind "ref.null nofunc"        # was ref.func
      else print ind "ref.null " bottom(th)
    } else if (tk == "SELECT") {
      print arr[ti]                                     # the producer, twice
      print arr[ti]
      print ind "i32.const 1"
      if (th == "") print ind "select"
      else print ind "select (result (ref null " th "))"
    } else if (tk == "BRNULL") {
      print ind "block $__nullmut (result (ref null " th "))"
      print arr[ti]
      print ind "br_on_non_null $__nullmut"
      print ind "ref.null " th
      print ind "end"
    }
  }
}
