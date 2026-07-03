# cond-gen-wat.awk — the WAT counterpart of cond-gen.awk: generate a WebAssembly
# text module full of (@if ...) annotations to fuzz conditional compilation on
# the *WAT* side (lib-wasm's Cond_specialize / the wat parser's annotation path),
# which cond-gen.awk (Wax #[if]) does not reach. -v seed=N is the only input.
#
# Same shape and intent as cond-gen.awk: globals guarded by random conditions,
# and a function that conditionally references them, so whether a configuration
# type-checks depends on the conditions' interplay over a shared variable subset
# (many combinations infeasible — the cond_solver stressor). WAT syntax differs:
# variables are $name, operators are prefix ((>= $ocaml_version (5 2 0))),
# combinators are (and ...)/(or ...)/(not ...), and (@else) is optional.

BEGIN {
  srand(seed)
  npool = split("wasi oxcaml cps jspi native effects ocaml_version", pool, " ")
  nsub = int(rand() * 3) + 2
  for (i = 1; i <= npool; i++) order[i] = i
  for (i = npool; i > 1; i--) { j = int(rand() * i) + 1; t = order[i]; order[i] = order[j]; order[j] = t }
  nvars = 0
  for (i = 1; i <= nsub && i <= npool; i++) { nvars++; vars[nvars] = pool[order[i]] }

  neff = split("jspi cps native other", effs, " ")
  nop = split(">= <= < > = <>", ops, " ")
  nvt = split("5,1,0 5,2,0 5,3,0 5,5,0", vts, " ")

  print "(module"
  print "  (func $sink (param i32))"
  ng = int(rand() * 3) + 2
  for (g = 0; g < ng; g++) {
    dcond[g] = cond(2)
    printf "  (@if %s (@then (global $g%d i32 (i32.const %d))))\n", dcond[g], g, g
  }
  print "  (func (export \"f\") (result i32)"
  for (g = 0; g < ng; g++) {
    use = (rand() < 0.5) ? ("(and " dcond[g] " " cond(1) ")") : cond(2)
    printf "    (@if %s (@then (call $sink (global.get $g%d))))\n", use, g
  }
  print "    (i32.const 0)))"
}

function ver_tuple(   v) { v = vts[int(rand() * nvt) + 1]; gsub(",", " ", v); return "(" v ")" }

function atom(   v) {
  v = vars[int(rand() * nvars) + 1]
  if (v == "effects") return "(= $effects \"" effs[int(rand() * neff) + 1] "\")"
  if (v == "ocaml_version") return "(" ops[int(rand() * nop) + 1] " $ocaml_version " ver_tuple() ")"
  return (rand() < 0.5) ? ("$" v) : ("(not $" v ")")
}

function cond(depth,   r, n, i, s) {
  if (depth > 0 && rand() < 0.6) {
    r = int(rand() * 3)
    if (r == 0) return "(not " cond(depth - 1) ")"
    n = int(rand() * 2) + 2
    s = cond(depth - 1)
    for (i = 2; i <= n; i++) s = s " " cond(depth - 1)
    return (r == 1 ? "(and " : "(or ") s ")"
  }
  return atom()
}
