# cond-gen.awk — generate a synthetic Wax module full of #[if] conditionals, to
# fuzz the conditional-compilation subsystem (Cond_explore / Cond_specialize /
# cond_solver) with conditions the corpus never contains. -v seed=N is the only
# input; output is a complete, parseable module.
#
# Shape: N top-level globals, each guarded by a random condition, and a function
# whose body conditionally *references* each global (guarded by another random
# condition). A reference included when its global is not defined is unbound, so
# whether a configuration type-checks depends on the interplay of the two
# conditions — and, because both draw from the SAME small variable subset, many
# combinations are infeasible. That is exactly what exercises cond_solver's
# feasibility pruning and Cond_explore's path-sensitive validation; the driver
# then checks the verdict against every concrete -D assignment.
#
# Conditions use a random 2-4 variable subset (so the driver can still enumerate
# all configurations exhaustively) built from booleans, the string `effects`,
# and version comparisons on `ocaml_version`, combined with all/any/not.

BEGIN {
  srand(seed)
  # Pick a random subset (2-4) of the known variables for this module.
  npool = split("wasi oxcaml cps jspi native effects ocaml_version", pool, " ")
  nsub = int(rand() * 3) + 2
  # Fisher-Yates-ish pick.
  for (i = 1; i <= npool; i++) order[i] = i
  for (i = npool; i > 1; i--) { j = int(rand() * i) + 1; t = order[i]; order[i] = order[j]; order[j] = t }
  nvars = 0
  for (i = 1; i <= nsub && i <= npool; i++) { nvars++; vars[nvars] = pool[order[i]] }

  neff = split("jspi cps native other", effs, " ")
  nop = split(">= <= < > =", ops, " ")
  nvt = split("5,1,0 5,2,0 5,3,0 5,5,0", vts, " ")

  print "fn sink(x: i32) {}"                        # consumes a value without a let
  ng = int(rand() * 3) + 2                          # 2-4 globals
  for (g = 0; g < ng; g++) {
    dcond[g] = cond(2)                               # this global's definition condition
    printf "#[if(%s)] {\n", dcond[g]                  # a top-level #[if] gates a braced field group
    printf "const g%d: i32 = %d;\n", g, g
    printf "}\n"
  }
  printf "\n#[export = \"f\"]\nfn f() -> i32 {\n"
  for (g = 0; g < ng; g++) {
    # An instruction-level #[if] gates a block and REQUIRES an #[else] (unlike a
    # top-level one, which gates a braced field group with no #[else]). The then-block references
    # g%d. Half the time the use condition is [all(def, ...)], which IMPLIES the
    # global is defined — so the module type-checks only if cond_solver proves
    # the unbound combination infeasible; otherwise it is independent and the
    # combination is reachable, so a config is ill-typed. This yields a mix of
    # accepted and rejected modules, exercising both directions of the oracle.
    use = (rand() < 0.5) ? ("all(" dcond[g] ", " cond(1) ")") : cond(2)
    printf "    #[if(%s)] { sink(g%d); } #[else] { }\n", use, g
  }
  printf "    0;\n}\n"
}

function ver_tuple(   v) { v = vts[int(rand() * nvt) + 1]; gsub(",", ", ", v); return "(" v ")" }

function atom(   v) {
  v = vars[int(rand() * nvars) + 1]
  if (v == "effects") return "effects = \"" effs[int(rand() * neff) + 1] "\""
  if (v == "ocaml_version") return "ocaml_version " ops[int(rand() * nop) + 1] " " ver_tuple()
  return (rand() < 0.5) ? v : "not(" v ")"           # boolean, maybe negated
}

function cond(depth,   r, n, i, s) {
  if (depth > 0 && rand() < 0.6) {
    r = int(rand() * 3)
    if (r == 0) return "not(" cond(depth - 1) ")"
    n = int(rand() * 2) + 2
    s = cond(depth - 1)
    for (i = 2; i <= n; i++) s = s ", " cond(depth - 1)
    return (r == 1 ? "all(" : "any(") s ")"
  }
  return atom()
}
