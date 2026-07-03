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

BEGIN { n = split("i32 i64 f32 f64", VT, " ") }

{ text = text $0 "\n" }

END {
  srand(seed)
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
