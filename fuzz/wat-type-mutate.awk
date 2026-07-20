# wat-type-mutate.awk — apply ONE targeted value-type flip to a WAT module, to
# fuzz the Wasm validator's rejection arms (lib-wasm/validation.ml). -v seed=N
# selects which occurrence to flip and the replacement type. Reads WAT on stdin
# (or a file arg), writes the mutant to stdout.
#
# Why: validation.ml is a ~170-line-per-instruction type checker whose REJECTION
# arms ("this instruction expects i32 but the stack has f64") the corpus never
# reaches — every corpus module is well-typed, so validation always takes the
# accept path. The mutate-wat literal fuzzer perturbs numbers, not types, so it
# does not reach them either. Flipping a single value type in an otherwise-valid
# module makes it "malformed but close": validation runs normally until it
# reaches the one now-ill-typed instruction and takes its rejection arm — one
# error deep in a real module, rather than the shallow first-error bail a
# from-scratch garbage generator would trigger.
#
# It flips a value-type token wherever it occurs — a (param/result/local ...)
# annotation, or an instruction prefix (i32.const, f64.add, ...) — since either
# creates a downstream stack-type mismatch. The paired driver is validate-fuzz.sh,
# whose differential oracle checks wax's verdict on the mutant against the
# reference validator: they must AGREE (both reject the now-invalid module); a
# wax-accepts / reference-rejects split is a validator hole (FALSE_ACCEPT).
#
# -v mode=cross instead applies ONE cross-proposal production (driver:
# wat-cross-proposal.sh, a crash-only oracle — mutants need not stay valid):
#   1. exact-wrap:   (ref [null] $t|N)  ->  (ref [null] (exact $t|N))
#   2. cont-splice:  after a (type $f (func ...)) declaration, splice a
#                    (type $__xcont (cont $f)) wrapper and retarget the first
#                    (ref [null] $f) at it
#   3. descriptor-pair: rewrite a (type $a (struct ...)) into a rec group whose
#                    two struct members are linked by (descriptor)/(describes)
# These graft one proposal's construct onto a module shaped by another — the
# input class behind the switch-on-(ref (exact $cont)) assert, which no
# generator (wasm-smith knows neither proposal) and no single-proposal corpus
# module could reach.

BEGIN { n = split("i32 i64 f32 f64", VT, " ") }

{ text = text $0 "\n" }

# End index (exclusive) of the s-expression opening at text[start] — a balanced
# paren scan; type declarations carry no strings, so quotes are not tracked.
function sexp_end(start,    d, i, c) {
  d = 0
  for (i = start; i <= length(text); i++) {
    c = substr(text, i, 1)
    if (c == "(") d++
    else if (c == ")") { d--; if (d == 0) return i + 1 }
  }
  return length(text) + 1
}

# Production 1: wrap the k-th concrete (ref ...) into an exact reference.
function prod_exact(    s, base, npos, k, p, l, inner) {
  npos = 0; s = text; base = 0
  while (match(s, /\(ref[ \t]+(null[ \t]+)?[$0-9][^ \t\r\n()]*\)/)) {
    pos[npos] = base + RSTART; len[npos] = RLENGTH; npos++
    base += RSTART + RLENGTH - 1
    s = substr(text, base + 1)
  }
  if (npos == 0) return 0
  k = int(rand() * npos); p = pos[k]; l = len[k]
  # Everything between "(ref " / "(ref null " and ")" is the heap type.
  inner = substr(text, p, l)
  sub(/^\(ref[ \t]+(null[ \t]+)?/, "", inner); sub(/\)$/, "", inner)
  head = substr(text, p, l - length(inner) - 1)
  text = substr(text, 1, p - 1) head "(exact " inner "))" substr(text, p + l)
  return 1
}

# Production 2: splice a continuation wrapper after the k-th named func type.
function prod_cont(    s, base, npos, k, p, e, nm, rest) {
  npos = 0; s = text; base = 0
  while (match(s, /\(type[ \t]+\$[^ \t\r\n()]+[ \t]+\(func[ \t\r\n)]/)) {
    pos[npos] = base + RSTART; npos++
    base += RSTART
    s = substr(text, base + 1)
  }
  if (npos == 0) return 0
  k = int(rand() * npos); p = pos[k]
  nm = substr(text, p); match(nm, /\$[^ \t\r\n()]+/); nm = substr(nm, RSTART, RLENGTH)
  e = sexp_end(p)
  text = substr(text, 1, e - 1) " (type $__xcont (cont " nm "))" substr(text, e)
  # Retarget the first reference to the wrapped type at the wrapper.
  rest = substr(text, e)
  if (match(rest, "\\(ref[ \t]+(null[ \t]+)?\\" nm "\\)")) {
    p = e - 1 + RSTART
    head = substr(text, p, RLENGTH - length(nm) - 1)
    text = substr(text, 1, p - 1) head "$__xcont)" substr(text, p + RLENGTH)
  }
  return 1
}

# Production 3: link the k-th named struct type to a fresh descriptor struct.
function prod_desc(    s, base, npos, k, p, e, nm, whole) {
  npos = 0; s = text; base = 0
  while (match(s, /\(type[ \t]+\$[^ \t\r\n()]+[ \t]+\(struct[ \t\r\n)]/)) {
    pos[npos] = base + RSTART; npos++
    base += RSTART
    s = substr(text, base + 1)
  }
  if (npos == 0) return 0
  k = int(rand() * npos); p = pos[k]; e = sexp_end(p)
  whole = substr(text, p, e - p)
  match(whole, /\$[^ \t\r\n()]+/); nm = substr(whole, RSTART, RLENGTH)
  # "(type $a REST)" -> "(rec (type $a (descriptor $__xd) REST) (type ...))"
  sub("^\\(type[ \t]+\\" nm "[ \t]+", "", whole); sub(/\)$/, "", whole)
  text = substr(text, 1, p - 1) \
    "(rec (type " nm " (descriptor $__xd) " whole ") (type $__xd (describes " nm ") (struct)))" \
    substr(text, e)
  return 1
}

END {
  srand(seed)
  if (mode == "cross") {
    # Pick a production; fall through to the others when it has no match site
    # (a module with no struct types still gets an exact-wrap, etc.).
    p0 = int(rand() * 3)
    for (t = 0; t < 3; t++) {
      p = (p0 + t) % 3
      if (p == 0 && prod_exact()) break
      if (p == 1 && prod_cont()) break
      if (p == 2 && prod_desc()) break
    }
    printf "%s", text
    exit
  }
  # Collect the offsets of every value-type token: a VT word delimited by a
  # non-alphanumeric on the left and by whitespace / '.' / ')' on the right (so
  # `i32.const` and `(local i32)` match, but `i32x4` and identifiers do not).
  npos = 0
  for (i = 1; i <= n; i++) {
    s = text
    base = 0
    while (match(s, "[^A-Za-z0-9_]" VT[i] "[ \t\r\n.)]")) {
      # RSTART points at the delimiter before the type; the type starts at +1.
      pos[npos] = base + RSTART + 1
      typ[npos] = VT[i]
      npos++
      base += RSTART + RLENGTH - 1
      s = substr(text, base + 1)
    }
  }
  if (npos == 0) { printf "%s", text; exit }

  # Pick one occurrence and a different replacement type (deterministic).
  k = int(rand() * npos)
  p = pos[k]
  old = typ[k]
  do { repl = VT[int(rand() * n) + 1] } while (repl == old)

  printf "%s%s%s", substr(text, 1, p - 1), repl, substr(text, p + length(old))
}
